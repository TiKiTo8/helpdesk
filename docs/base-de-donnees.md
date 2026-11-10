# Base de données, réplication et sauvegardes

Partie gérée par Luka : les services `db`, `db-replica` et `backup`, et leurs volumes.

## Ce qu'on a mis en place

Trois conteneurs, tous sur le réseau interne `backend`, sans aucun port ouvert vers l'extérieur :

- **db** : la base principale, PostgreSQL 18. C'est elle qui reçoit toutes les écritures. Ses données sont dans le volume `db-data`.
- **db-replica** : une copie de `db`, en lecture seule, mise à jour en continu. Ses données sont dans `db-replica-data`.
- **backup** : fait une sauvegarde de la base toutes les heures et garde les 7 dernières dans le volume `backups`.

```
  db (écritures) ──── réplication ────► db-replica (lecture seule) ◄──── pg_dump ──── backup
     db-data                               db-replica-data                             backups
```

## Pourquoi PostgreSQL

Un helpdesk, ce sont des tickets, des utilisateurs, des commentaires, des données liées entre elles. Une base relationnelle est donc le choix naturel. Entre PostgreSQL et MariaDB, les deux auraient marché, mais PostgreSQL a trois avantages pour nous :

- la réplication est intégrée, une seule commande suffit à créer le réplica (`pg_basebackup`) ;
- `pg_dump` sauvegarde la base sans bloquer les écritures ;
- il est plus strict sur les types et les contraintes, donc la base refuse elle-même les données incohérentes.

On a écarté MongoDB (il faudrait gérer les liens entre tickets et utilisateurs dans le code) et SQLite (pas de serveur, pas de réplication).

On a pris la **version 18**, la dernière stable, maintenue jusqu'en 2030, et l'image **Alpine**, environ 3 fois plus légère que la version Debian. Seul souci d'Alpine : elle trie mal les accents (`Zoo` passe avant `abri`). On l'a réglé en demandant à Postgres de trier en français avec ICU.

L'image est fixée par son empreinte `sha256`, comme vu en cours : tout le monde récupère exactement la même image, aujourd'hui comme dans six mois.

## La réplication

Au premier démarrage, le réplica copie entièrement la base principale avec `pg_basebackup`. Ensuite, il reçoit chaque modification en continu, via le journal de Postgres (le WAL). Il est en lecture seule : toute tentative d'écriture est refusée.

Quelques choix :

- **Réplication asynchrone** : la base principale n'attend pas le réplica pour valider une écriture. Si le réplica tombe, l'appli continue de fonctionner.
- **Un compte `replicator` dédié**, qui a seulement le droit de répliquer. Il ne peut pas lire les tables.
- **256 Mo de journal conservés** sur la base principale (`wal_keep_size`), pour qu'un réplica arrêté un moment puisse rattraper son retard en redémarrant.
- **Pas de bascule automatique** si la base principale tombe. Ce n'était pas demandé, mais on sait comment faire (voir les améliorations).

Attention, le réplica n'est pas une sauvegarde : si quelqu'un supprime tous les tickets, la suppression est copiée sur le réplica en quelques millisecondes. Le réplica protège d'une panne, la sauvegarde protège d'une erreur.

## Les sauvegardes

Le conteneur `backup` lance `pg_dump` toutes les heures. Il lit le **réplica**, pour ne pas ralentir la base principale, et se rabat sur `db` si le réplica est absent. Chaque sauvegarde est compressée (format `-Fc` avec zstd) et peut être restaurée en entier ou table par table.

Deux détails qui comptent :

- le dump est d'abord écrit dans un fichier `.tmp`, renommé seulement s'il s'est bien terminé, pour qu'une sauvegarde coupée en plein milieu ne soit jamais prise pour une vraie ;
- seules les 7 plus récentes sont gardées, les autres sont supprimées.

On a gardé un **volume nommé** plutôt qu'un dossier du PC (bind mount). La consigne parle d'un volume, et avec un bind mount les fichiers auraient appartenu à un utilisateur du conteneur qui n'existe pas sur nos PC, ce qui pose des problèmes de droits, différents sous Windows et sous Linux.

## La sécurité

On a appliqué ce qu'on a vu en cours :

- **Les mots de passe sont des secrets**, pas des variables d'environnement. Chacun est un fichier de `secrets/`, monté dans le conteneur sous `/run/secrets/`. Avec des variables, n'importe qui pouvait les lire avec `docker inspect`.
- **Aucun conteneur ne tourne en root** : les trois tournent avec l'utilisateur `postgres`.
- **L'application a son propre compte, `app`**, qui peut lire, créer et modifier des tickets, mais pas en supprimer, ni toucher à la structure de la base. Même avec une faille dans l'appli, on ne peut pas vider la base.
- **Les sauvegardes ne sont lisibles que par `postgres`**, puisqu'elles contiennent toute la base.
- **Chaque conteneur a des limites** de mémoire, de CPU et de nombre de processus, et ses logs tournent (3 fichiers de 10 Mo maximum).

## Les healthchecks

- **db** est considéré comme prêt quand il accepte des connexions par le réseau.
- **db-replica** est sain seulement si la réplication tourne vraiment, pas juste si Postgres répond.
- **backup** est sain seulement si la dernière sauvegarde a moins de deux heures.

Le réplica et la sauvegarde attendent que `db` soit sain avant de démarrer (`depends_on` avec `condition: service_healthy`).

## Commandes utiles

```bash
# Vérifier la réplication
docker compose exec db-replica psql -U helpdesk -c "SELECT pg_is_in_recovery(), count(*) FROM tickets;"

# Lancer une sauvegarde tout de suite, lister les sauvegardes, en restaurer une
docker compose exec backup sh /scripts/backup.sh now
docker compose exec backup sh /scripts/restore.sh
docker compose exec backup sh /scripts/restore.sh <fichier>.dump

# Récupérer les sauvegardes sur son PC
docker compose cp backup:/var/lib/postgresql/backups ./backups-export
```

## La démo

1. `docker compose ps` : les trois services sont `healthy`.
2. On crée un ticket dans l'appli, il apparaît sur le réplica.
3. On essaie d'écrire sur le réplica : refusé.
4. On arrête le réplica, on crée deux tickets, on le relance : il rattrape son retard.
5. On vide la table, on restaure la dernière sauvegarde : les tickets reviennent, sur la base et sur le réplica.
6. `docker compose down` puis `up` : tout est toujours là.

## Le lien avec l'application

Le service `api` est branché sur la base. Il se connecte à `db` avec l'utilisateur `app` et lit son mot de passe dans le secret `/run/secrets/app_password`, comme les autres services : l'ancienne variable `DATABASE_URL`, qui contenait le mot de passe en clair, a disparu. Les statistiques sont lues sur `db-replica`, puisqu'elles peuvent avoir quelques millisecondes de retard ; si le réplica ne répond pas, l'appli passe par `db`.

Le service `api` est sur le réseau `backend` et attend que `db` soit sain avant de démarrer. Pour qu'il soit accessible depuis le navigateur, il faudra l'ajouter aussi au réseau du reverse proxy.

## Les difficultés rencontrées

**L'exemple du cours ne marche plus en version 18.** Il monte le volume sur `/var/lib/postgresql/data`. Depuis la v18, l'image range ses données ailleurs et s'arrête avec une erreur. Il faut monter le volume sur `/var/lib/postgresql`.

**Un ancien volume bloquait le démarrage.** En testant sur Windows, `db` restait `unhealthy`. Le volume `db-data` existait déjà, d'un premier essai en version 17, et Postgres 18 refuse de démarrer sur des données d'une autre version. La solution : `docker compose down -v` pour repartir de volumes vides.

**Le mot de passe de réplication écrit en clair.** En testant, on a vu que `pg_basebackup` recopiait le mot de passe dans la configuration du réplica. On passe maintenant par un fichier `.pgpass`, et la configuration ne contient plus que son chemin.

**Les droits sur les volumes sans root.** Un volume monté sur un dossier qui n'existe pas dans l'image appartient à root, donc l'utilisateur `postgres` ne pouvait pas y écrire. On monte tout sur `/var/lib/postgresql`, qui appartient déjà à `postgres` dans l'image : le volume hérite de ce propriétaire.

**Le conteneur de sauvegarde mettait 10 secondes à s'arrêter.** Le script ignorait le signal d'arrêt de Docker, qui finissait par le tuer (code 137). Avec un `trap`, il s'arrête maintenant tout de suite et proprement.

**La base annoncée prête trop tôt.** Pendant son initialisation, Postgres tourne quelques secondes sans être joignable par le réseau. Le healthcheck le teste donc par le réseau (`-h 127.0.0.1`), sinon les autres services se connectaient trop tôt.

**Le réplica annoncé sain alors qu'il ne répliquait plus.** `pg_isready` dit seulement si Postgres répond. On vérifie maintenant l'état de la réplication elle-même.

**Les mots de passe avec des caractères spéciaux.** Une apostrophe cassait le script de création du compte, et `:` casse le format `.pgpass`. Les deux sont maintenant échappés, et les retours à la ligne ajoutés par Windows sont retirés.

**Les scripts cassés sous Windows.** Git convertit parfois les fins de ligne. Le fichier `.gitattributes` force le format Linux pour les `.sh`.

## Ce qu'on améliorerait

- **Bascule en cas de panne** : aujourd'hui, si la base principale tombe, il faut promouvoir le réplica à la main (`SELECT pg_promote();`). Des outils comme Patroni le font automatiquement.
- **Sauvegardes hors de la machine** : elles sont sur le même PC que la base. La règle 3-2-1 veut 3 copies, sur 2 supports, dont 1 ailleurs (un NAS, un stockage S3).
- **Tester les restaurations automatiquement**, parce qu'une sauvegarde qu'on n'a jamais restaurée n'est pas fiable.
- **Restaurer à la seconde près** en archivant le journal (pgBackRest), au lieu de perdre jusqu'à une heure de données.
- **Chiffrer les secrets et les sauvegardes** : hors Swarm, un secret Compose est un simple fichier, pas chiffré.
- **Superviser la base** avec `postgres-exporter` et des alertes : retard de réplication, sauvegarde trop ancienne.
- **Un outil de migrations** (Alembic, Flyway, etc.) pour faire évoluer le schéma sans supprimer les données.

## Comment optimiser

- Mesurer avant d'optimiser, avec `EXPLAIN ANALYZE`.
- Ajouter un index quand la table grossit, par exemple `CREATE INDEX ON tickets (status, created_at DESC);`.
- Paginer la liste des tickets (`WHERE id < ... LIMIT 20`) plutôt que de tout renvoyer.
- Envoyer les lectures lourdes (statistiques, exports) sur le réplica, pour laisser la base principale aux écritures.
- Ajuster la mémoire de Postgres (`shared_buffers`) une fois qu'on connaît la charge réelle.
- Pour une grosse base, faire des sauvegardes en parallèle (`pg_dump -Fd -j 4`).
