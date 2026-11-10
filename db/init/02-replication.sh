#!/bin/sh
# Joué une seule fois, à l'initialisation du primaire (volume db-data vide).
# Crée un compte dédié à la réplication et l'autorise à se connecter en mode réplication.
set -e

# Moindre privilège : REPLICATION seulement, aucun accès aux tables.
# :'pw' laisse psql échapper le mot de passe : une apostrophe ne casse pas la requête.
psql -v ON_ERROR_STOP=1 -v pw="$REPLICATION_PASSWORD" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'pw';
SQL

# Les connexions de réplication ne sont pas couvertes par la règle "host all all" de l'image.
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
