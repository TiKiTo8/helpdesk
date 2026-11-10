#!/bin/sh
# Compte utilisé par l'application : lire, créer et modifier des tickets, rien d'autre.
set -e

password="$(tr -d '\r\n' < "$APP_PASSWORD_FILE")"

psql -v ON_ERROR_STOP=1 -v password="$password" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE ROLE app WITH LOGIN PASSWORD :'password';

GRANT CONNECT ON DATABASE :"DBNAME" TO app;
GRANT USAGE ON SCHEMA public TO app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app;

-- Mêmes droits sur les tables créées plus tard
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE ON SEQUENCES TO app;
SQL
