# Base de données, réplication & sauvegardes

Responsable : Luka — services `db`, `db-replica`, `backup` ; volumes `db-data`, `db-replica-data`, `backups`.

---

## 1. Choix techniques

### PostgreSQL 18 plutôt que MariaDB ou MongoDB

Ce n'est pas « la meilleure base » dans l'absolu : c'est celle qui coche le mieux **nos** critères.

| Critère | Pourquoi PostgreSQL |
|---|---|
| Données d'un helpdesk | Tickets, utilisateurs, commentaires sont liés entre eux : c'est du relationnel. Les contraintes (`NOT NULL`, `CHECK`, clés étrangères) protègent les données au niveau de la base, pas seulement dans le code. |
| Réplication master / slave | Intégrée : `pg_basebackup -R` clone le primaire, puis le réplica rejoue son journal (WAL) en continu. Aucun outil externe. |
| Sauvegardes | `pg_dump` fait un instantané cohérent **sans bloquer** les écritures, `pg_restore` restaure tout ou partie. |
| Indépendance vis-à-vis de l'appli | Pilotes pour Python, Node, PHP, Java… L'équipe appli garde le choix du langage. |
| Image Docker | Image officielle maintenue, variante `alpine` légère, `pg_isready` pour le healthcheck. |

**Alternatives écartées :**
- **MariaDB / MySQL** : tout à fait valable (réplication par binlog, `mariadb-dump`). PostgreSQL est plus strict sur les types et les contraintes, et sa réplication se met en place en une commande.
- **MongoDB** : base de documents. Les liens ticket ↔ utilisateur seraient à gérer dans le code, et le replica set (bascule automatique) dépasse ce qui est demandé.
- **SQLite** : un fichier, sans serveur ni réplication. Exclu par la consigne.

### Réplication : streaming asynchrone, physique

| Choix | Pourquoi | Alternative écartée |
|---|---|---|
| Réplication **physique** (copie du WAL) | Le réplica est une copie octet pour octet : toutes les tables, sans rien configurer table par table. | Réplication logique : utile pour ne copier qu'une partie des tables, plus de configuration. |
| **Asynchrone** | Le primaire n'attend pas le réplica : une panne du réplica ne bloque pas les écritures. | Synchrone : zéro perte de données, mais si le réplica tombe, le primaire ne peut plus écrire. |
| Compte `replicator` dédié | Moindre privilège : droit `REPLICATION` seulement, aucun accès aux tables. | Réutiliser le superutilisateur. |
| Clonage au premier démarrage, dans l'entrypoint | Le réplica se construit tout seul depuis zéro : reproductible. | Copie manuelle d'un dump : étape humaine, non reproductible. |
| Pas de bascule automatique | Hors consigne ; on sait expliquer comment la faire (§4). | Patroni / repmgr : plusieurs conteneurs de plus. |

### Sauvegardes : `pg_dump` en boucle dans un conteneur dédié

| Choix | Pourquoi | Alternative écartée |
|---|---|---|
| Conteneur `backup` séparé | Une responsabilité par conteneur. | Script lancé depuis l'hôte : pas reproductible. |
| Lecture sur le **réplica** | Le dump ne charge pas le primaire qui sert l'appli. Repli sur le primaire si le réplica est absent. | Toujours sur le primaire. |
| Même image que la base | `pg_dump` doit être de version ≥ au serveur ; aucune image de plus. | Image tierce : une dépendance de plus à justifier. |
| Dump logique `-Fc -Z zstd` | Cohérent, compressé, restaurable table par table. | Copier les fichiers du volume : incohérent si la base écrit pendant la copie. |
| Boucle `sleep` | Simple à lire et à expliquer. | `cron` : un démon de plus ; pgBackRest : trop lourd ici. |
| Volume nommé `backups` | La consigne demande un volume ; les sauvegardes survivent à la suppression des conteneurs ; aucun problème de propriétaire de fichiers. | Bind mount `./backups` (le cours le classe pour les backups) : fichiers directement sur l'hôte, mais créés par l'UID 70 du conteneur, qui n'existe pas sur l'hôte, et comportement différent sous Windows et Linux. |

### Sécurité : comme vu en cours

| Choix | Pourquoi | Alternative écartée |
|---|---|---|
| Mots de passe en **secrets** (`secrets/*.txt` → `/run/secrets/<nom>`) | Le cours : un mot de passe en variable d'environnement est « très mauvaise idée », visible avec `docker inspect`. Vérifié : 0 occurrence dans `docker inspect` des 3 conteneurs. | Variables `POSTGRES_PASSWORD` dans le `.env`. |
| `POSTGRES_PASSWORD_FILE` | Prévu par l'image officielle : elle lit le mot de passe dans le fichier. | Script maison. |
| Réplica : fichier `.pgpass` (droits `600`) régénéré à chaque démarrage | Avec une variable, `pg_basebackup -R` recopie le mot de passe **en clair** dans la configuration du réplica. Avec un fichier, elle ne contient que son chemin. | `PGPASSWORD`. |
| Scripts de sauvegarde : mot de passe lu dans le secret au lancement | Il ne vit que dans la mémoire du processus : ni dans la config du conteneur, ni sur le disque. | Variable d'environnement du conteneur. |
| **Aucun conteneur en root** (`user: postgres`, UID 70) | Le cours range le root par défaut dans les pratiques dangereuses. Les volumes sont montés sur `/var/lib/postgresql`, qui appartient à `postgres` dans l'image : ils en héritent, donc pas besoin de root pour les préparer. | Démarrer en root puis rétrograder (ce que fait l'image par défaut). |
| Compte `app` pour l'application | Moindre privilège : `SELECT`, `INSERT`, `UPDATE` sur les tickets, rien d'autre. Vérifié : `DELETE`, `DROP TABLE` et `CREATE TABLE` sont refusés. Une faille dans l'appli (injection SQL) ne peut ni vider ni détruire la base. | L'appli connectée en superutilisateur, qui peut tout faire. |
| Sauvegardes en `600` (`umask 077`) | Un dump contient toute la base. | Fichiers lisibles par tous. |
| Image fixée par empreinte `sha256` | Reproductibilité : exactement la même image à chaque installation (cours, p. 44). | Tag seul, qui peut pointer vers une autre image demain. |
| Limites RAM / CPU / processus, rotation des logs | Un conteneur ne peut ni saturer l'hôte, ni remplir le disque de logs (cours, p. 70-71). | Aucune limite. |

> **Le réplica n'est pas une sauvegarde.** Un `DELETE` est répliqué en quelques millisecondes. Le réplica protège d'une panne de machine ; la sauvegarde protège d'une erreur humaine.

---

## 2. Fonctionnement

```
                 réseau backend (internal : aucun accès extérieur)

  ┌──────────────┐   WAL en continu   ┌──────────────┐   pg_dump   ┌──────────┐
  │ db (master)  ├───────────────────►│ db-replica   │◄────────────┤ backup   │
  │ lecture +    │                    │ (slave)      │             │          │
  │ écriture     │◄─ restauration ────┤ lecture seule│             │          │
  └──────┬───────┘                    └──────┬───────┘             └────┬─────┘
     db-data                           db-replica-data               backups
```

**Avant le premier démarrage :** créer les deux fichiers de mots de passe (voir `secrets/README.md`). Sans eux, Compose refuse de démarrer.

**Premier démarrage, dans l'ordre :**
1. `db` : volume vide → Postgres s'initialise et joue `db/init/` : création de la table (`01-schema.sql`), du compte `replicator` et de son autorisation dans `pg_hba.conf` (`02-replication.sh`), du compte `app` et de ses droits (`03-app-user.sh`).
2. `db` devient `healthy` (`pg_isready` en TCP).
3. `db-replica` démarre : il écrit son fichier `.pgpass` depuis le secret ; volume vide → `pg_basebackup -R -X stream` clone le primaire. `-R` crée `standby.signal` : Postgres démarre en **lecture seule** et suit le primaire.
4. `backup` démarre, fait une première sauvegarde, puis une toutes les `BACKUP_INTERVAL` secondes, en gardant les `BACKUP_KEEP` plus récentes.

**Démarrages suivants :** les volumes sont remplis, aucun script d'init ni clonage n'est rejoué.

**Healthchecks :**

| Service | Sain quand… |
|---|---|
| `db` | il accepte les connexions TCP |
| `db-replica` | le flux de réplication est `streaming` (`pg_stat_wal_receiver`), pas seulement « Postgres répond » |
| `backup` | la dernière sauvegarde a moins de deux intervalles |

### Commandes

```bash
# La réplication fonctionne : le réplica est en lecture seule et a les mêmes données
docker compose exec db-replica psql -U helpdesk -c "SELECT pg_is_in_recovery(), count(*) FROM tickets;"
docker compose exec db psql -U helpdesk -c "SELECT usename, state FROM pg_stat_replication;"

# Sauvegardes
docker compose exec backup sh /scripts/backup.sh now           # sauvegarde immédiate
docker compose exec backup sh /scripts/restore.sh              # liste
docker compose exec backup sh /scripts/restore.sh <fichier>    # restauration (écrase les données)
docker compose cp backup:/var/lib/postgresql/backups ./backups-export   # copie sur la machine hôte

# Vérifier qu'aucun conteneur ne tourne en root
docker compose exec db id        # uid=70(postgres)
```

### Démo (≈ 1 min 30)

1. `docker compose ps` → `db`, `db-replica`, `backup` sont `healthy`.
2. Créer un ticket dans l'appli → il apparaît sur le réplica (commande ci-dessus).
3. Écrire sur le réplica → `cannot execute INSERT in a read-only transaction`.
4. `docker compose stop db-replica`, créer 2 tickets, `docker compose start db-replica` → le réplica rattrape son retard.
5. Vider la table, restaurer la dernière sauvegarde → les tickets reviennent, sur le primaire **et** sur le réplica.
6. `docker compose down` puis `up` → tout est toujours là.

### Interface pour le reste de l'équipe

| Pour | Information |
|---|---|
| Application — écritures | hôte `db`, port `5432`, utilisateur **`app`**, base `POSTGRES_DB`. Mot de passe : ajouter le secret `app_password` au service et le lire dans `/run/secrets/app_password`, plutôt qu'un mot de passe dans `DATABASE_URL`. |
| Application — lectures qui tolèrent un léger retard (stats, rapports) | mêmes identifiants, hôte `db-replica` (le compte `app` y existe aussi, la réplication copie tout) |
| Compose | réseau `backend` ; `depends_on: db: { condition: service_healthy }` |

---

## 3. Difficultés rencontrées

| Problème | Cause | Solution |
|---|---|---|
| Réplica en redémarrage en boucle | En v17, les données étaient à la racine du volume, créée par Docker en `0755` ; Postgres exige `0700`. | Corrigé d'abord par un `chmod 700`. En v18, les données sont dans un sous-dossier créé par `pg_basebackup` lui-même en `0700` : le `chmod` est devenu inutile et a été retiré. |
| `docker compose stop backup` : 10 s d'attente puis code 137 | Le script tourne en PID 1 : sans gestionnaire, le signal d'arrêt est ignoré, Docker attend 10 s puis tue le conteneur (SIGKILL). | `trap 'exit 0' TERM` et `sleep & wait` : arrêt en 0,2 s, code 0. |
| Connexion de réplication refusée | La règle `host all all` de l'image ne couvre pas le mode réplication. | Ligne `host replication replicator all scram-sha-256` ajoutée dans `pg_hba.conf` à l'init. |
| `db` déclaré sain avant d'être prêt | Pendant l'init, Postgres démarre un serveur temporaire qui n'écoute que sur son socket Unix. | `pg_isready -h 127.0.0.1` : test en TCP. |
| Réplica « healthy » alors qu'il ne réplique plus | `pg_isready` dit seulement que Postgres répond. | Healthcheck sur `pg_stat_wal_receiver.status = streaming`. |
| Réplica arrêté longtemps → impossible de reprendre | Le primaire recycle son journal ; le réplica ne retrouve plus les segments manquants. | `wal_keep_size=256MB` sur le primaire. |
| Mot de passe avec une apostrophe → script d'init cassé | Mot de passe collé dans la requête SQL. | Variable psql `:'pw'`, échappée par psql. Testé avec `rep'li`. |
| Mots de passe visibles avec `docker inspect` | Ils étaient passés en variables d'environnement. | Secrets Compose (fichiers montés dans `/run/secrets/`). |
| Mot de passe de réplication en clair sur le disque du réplica | `pg_basebackup -R` recopie dans `postgresql.auto.conf` le mot de passe reçu par variable. Vu en testant. | Connexion avec un fichier `.pgpass` : la config ne contient que `passfile=…`. |
| `postgres` ne peut pas écrire dans le volume de sauvegarde | Un volume monté sur un chemin absent de l'image (`/backups`) appartient à root. | Monter sur `/var/lib/postgresql`, qui appartient à `postgres` dans l'image : le volume en hérite. |
| Exemple du cours (v18 + volume sur `/var/lib/postgresql/data`) : le conteneur s'arrête | Depuis la v18, l'image range les données dans `/var/lib/postgresql/18/docker` et refuse l'ancien point de montage. | Volume monté sur `/var/lib/postgresql`. |
| Mot de passe avec `:`, `'` ou `\`, ou fichier créé sous Windows (CRLF) | `:` et `\` sont des séparateurs du format `.pgpass` ; Windows ajoute `\r\n`. | Échappement dans le `.pgpass`, suppression de `\r\n` à la lecture. Testé avec `R:e'p\li` et un fichier CRLF. |
| Tri des accents incorrect sous Alpine | La bibliothèque C d'Alpine (musl) trie octet par octet. | Collation ICU `fr-FR` à l'initialisation. |
| Sauvegarde partielle prise pour une vraie | `pg_dump` interrompu laisse un fichier incomplet. | Écriture en `.tmp`, renommé seulement en cas de succès. |
| Restauration sur une base existante | `pg_restore` échoue sur les tables déjà présentes ; un réplica refuse les écritures. | `--clean --if-exists --single-transaction`, toujours vers `db`. |
| Changer le schéma sans effet | `db/init/` n'est joué que sur un volume vide. | En dev : `docker compose down -v`. En prod : un outil de migrations (§4). |
| Scripts `.sh` cassés sous Windows | Conversion des fins de ligne en CRLF. | `.gitattributes` : `*.sh text eol=lf`. |

---

## 4. Améliorations possibles

**Haute disponibilité**
- Bascule manuelle si le primaire meurt : `SELECT pg_promote();` sur le réplica, puis pointer l'appli vers `db-replica`.
- Bascule automatique : Patroni ou repmgr, avec un point d'entrée unique (HAProxy, PgBouncer) qui suit le primaire.
- Slot de réplication (`pg_basebackup -C -S replica`) : le primaire garde tout le WAL nécessaire au réplica, quelle que soit la durée de la coupure. Contrepartie : un réplica disparu définitivement remplit le disque du primaire.
- Réplication synchrone si aucune perte de données n'est tolérée.

**Sécurité**
- Secrets chiffrés : en dehors de Swarm, un secret Compose est un simple fichier monté en lecture seule, non chiffré. Swarm ou un coffre-fort (Vault) les chiffrent.
- Supprimer aussi les capacités Linux inutiles (`cap_drop: [ALL]` puis le strict nécessaire), comme dans la démo de hardening du cours.
- Scanner les images (Trivy, Dockle) et le dépôt (Gitleaks) avant chaque livraison.
- Un compte de sauvegarde en lecture seule (`pg_read_all_data`) au lieu de l'administrateur pour `backup`.
- Chiffrer les sauvegardes (`age`, `gpg`) avant de les copier ailleurs.

**Sauvegardes**
- Règle 3-2-1 : 3 copies, 2 supports, 1 hors site. Aujourd'hui les dumps sont sur la même machine. → Envoi vers un stockage objet (S3, MinIO) ou un NAS.
- Tester la restauration automatiquement dans une base jetable : une sauvegarde jamais restaurée n'est pas une sauvegarde.
- Restauration à la seconde près (PITR) par archivage du WAL (pgBackRest, WAL-G).

**Exploitation**
- `postgres-exporter` + alertes : réplica `unhealthy`, retard de réplication, sauvegarde trop ancienne.
- Limites CPU / mémoire par service.
- Outil de migrations (Alembic, Flyway, Prisma… selon l'appli) pour faire évoluer le schéma sans perdre les données.

---

## 5. Optimiser

**Requêtes (avec l'équipe appli)**
- Mesurer avant d'optimiser : `EXPLAIN ANALYZE`.
- Index sur les colonnes filtrées et triées : `CREATE INDEX ON tickets (status, created_at DESC);`
- Pagination par curseur (`WHERE id < $dernier ORDER BY id DESC LIMIT 20`) plutôt que `OFFSET`, qui relit les lignes sautées.
- Requêtes paramétrées + pool de connexions côté appli.
- Envoyer les lectures lourdes (stats, exports) sur `db-replica` : le primaire reste disponible pour les écritures.

**Serveur**
- `shared_buffers` ≈ 25 % de la RAM allouée, `work_mem` selon les tris : `command: ["postgres", "-c", "shared_buffers=256MB"]`.
- PgBouncer devant Postgres si de nombreuses instances de l'appli ouvrent des connexions.

**Sauvegardes**
- Déjà en place : compression `zstd` et lecture sur le réplica.
- Grosse base : dump parallèle `pg_dump -Fd -j 4` (format répertoire, 4 processus).
- `BACKUP_INTERVAL` = perte de données acceptable (RPO) : toutes les heures = au pire une heure perdue.
