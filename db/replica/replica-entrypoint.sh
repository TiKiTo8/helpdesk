#!/bin/sh
# Démarrage du réplica (slave).
# Premier démarrage : clone complet du primaire avec pg_basebackup.
#   -R          écrit standby.signal + primary_conninfo : Postgres démarre en lecture seule
#               et rejoue en continu le journal (WAL) reçu du primaire.
#   -X stream   récupère aussi le WAL produit pendant la copie : le clone est cohérent.
# Démarrages suivants : les données sont déjà dans le volume, on démarre directement.
set -e

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "réplica vide : clonage du primaire…"
  pg_basebackup -h db -U replicator -D "$PGDATA" -R -X stream
fi

# Le dossier du volume est créé par Docker en 0755 ; Postgres refuse de démarrer si ce n'est pas 0700.
chmod 700 "$PGDATA"
exec postgres
