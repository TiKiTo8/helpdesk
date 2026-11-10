#!/bin/sh
set -e

# Mot de passe passé par fichier : avec PGPASSWORD, pg_basebackup -R l'écrirait en clair
# dans la configuration du réplica. Dans un .pgpass, ":" et "\" doivent être échappés.
passfile=/var/lib/postgresql/.pgpass
password="$(tr -d '\r\n' < /run/secrets/replication_password | sed 's/[\\:]/\\&/g')"
umask 077
printf 'db:5432:replication:replicator:%s\n' "$password" > "$passfile"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  pg_basebackup -d "host=db user=replicator passfile=$passfile" -D "$PGDATA" -R -X stream
fi

exec postgres
