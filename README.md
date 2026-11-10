# Helpdesk

Projet de conteneurisation B3 — groupe de 3, présentation de 15 min.

**Le projet :** une application de helpdesk (tickets de support) et son infrastructure web conteneurisée.

---

## Consignes et répartition

| Élément demandé | Responsable | Technologie choisie |
|---|---|---|
| Application (IA autorisée) | TOUS | *à définir* |
| `Dockerfile` pour le build de l'application | TOUS | — |
| Bind mounts pour partager le code / la configuration de l'application | Maxime | — |
| Reverse proxy qui facilite l'accès aux services (Traefik, Caddy, NGINX…) | Maxime | *à définir* |
| `compose.yml` | TOUS | — |
| Base de données avec un volume persistant | Luka | *à définir* |
| Réplication master / slave de la base | Luka | — |
| Volume pour sauvegarder les fichiers de manière persistante (backups) | Luka | *à définir* |
| Mailing et Monitoring | Baptiste | *à définir* |

| Membre | Nom |
|---|---|
| Membre 1 | |
| Membre 2 | |
| Membre 3 | |

---

## Critères de notation

| Critère | Responsable |
|---|---|
| Fonctionnel depuis zéro (reproductible) | Tous — vérifié par le Membre 1 |
| Bonnes pratiques | Chacun sur sa partie |
| Robustesse (healthchecks) | Chacun sur ses services |
| Persistance | Membre 3 |
| Proxy bien configuré (services accessibles via le reverse proxy) | Membre 1 |
| Clarté de la présentation / respect des 15 min | Tous |
| Cohérence (répond au besoin) | Tous |
| Partage des tâches | Tous |

---

## Pour la soutenance

Chaque membre doit être capable d'expliquer sur sa partie :

- comment ça fonctionne ;
- pourquoi ces choix ;
- comment optimiser le code ou la configuration.
