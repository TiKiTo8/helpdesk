#!/bin/sh
# Compte utilisé par le réplica. Joué une seule fois, à la création de la base.
set -e

password="$(tr -d '\r\n' < "$REPLICATION_PASSWORD_FILE")"

psql -v ON_ERROR_STOP=1 -v password="$password" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'password';
SQL

echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
