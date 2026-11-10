#!/bin/sh
# Restaure une sauvegarde dans la base primaire. ÉCRASE les données actuelles.
#   sh /scripts/restore.sh                       liste les sauvegardes disponibles
#   sh /scripts/restore.sh <fichier>.dump        restaure ce fichier
set -eu

if [ $# -eq 0 ]; then
  ls -1t /backups/*.dump
  exit
fi

file="/backups/$(basename "$1")"
[ -f "$file" ] || { echo "introuvable : $file" >&2; exit 1; }

# Toujours vers le primaire : un réplica est en lecture seule.
# --clean --if-exists : supprime puis recrée chaque objet ; --single-transaction : tout ou rien.
pg_restore -h db --clean --if-exists --no-owner --single-transaction -d "$PGDATABASE" "$file"
echo "restauration OK : $file"
