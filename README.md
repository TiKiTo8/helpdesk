# Helpdesk

Projet de conteneurisation en B3, à trois. Une application de tickets de support et toute l'infrastructure qui va avec, lancée avec Docker Compose.

## Qui fait quoi

| Ce qui est demandé | Qui s'en occupe | Avec quoi |
|---|---|---|
| L'application | Tout le monde | à définir |
| Le Dockerfile de l'application | Tout le monde | |
| Les bind mounts pour le code et la config | Maxime | |
| Le reverse proxy | Maxime | à définir |
| Le `compose.yml` | Tout le monde | |
| La base de données avec un volume persistant | Luka | PostgreSQL 18 |
| La réplication master / slave | Luka | réplication en streaming de PostgreSQL |
| Le volume de sauvegardes | Luka | `pg_dump` toutes les heures dans un volume |
| Le mailing et le monitoring | Baptiste | à définir |

## Ce qui sera noté

| Critère | Qui vérifie |
|---|---|
| Ça marche en partant de zéro | tout le monde, Maxime fait le test final |
| Les bonnes pratiques | chacun sur sa partie |
| Les healthchecks | chacun sur ses services |
| La persistance des données | Luka |
| Le reverse proxy (tous les services accessibles par lui) | Maxime |
| La présentation (15 min max) | tout le monde |
| La cohérence avec le besoin | tout le monde |
| Le partage des tâches | tout le monde |

## À savoir expliquer

Chacun doit pouvoir expliquer sa partie : comment elle marche, pourquoi on a fait ces choix et comment on pourrait l'améliorer.

La partie base de données est détaillée dans [docs/base-de-donnees.md](docs/base-de-donnees.md).
