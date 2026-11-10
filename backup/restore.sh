#!/bin/sh
# Usage : restore.sh             liste les sauvegardes
#         restore.sh <fichier>   restaure dans db (écrase les données actuelles)
set -eu

dir=/var/lib/postgresql/backups

if [ $# -eq 0 ]; then
  find "$dir" -name '*.dump' | sort -r
  exit
fi

file="$dir/$(basename "$1")"
if [ ! -f "$file" ]; then
  echo "introuvable : $file" >&2
  exit 1
fi

PGPASSWORD="$(tr -d '\r\n' < /run/secrets/db_password)"
export PGPASSWORD

pg_restore -h db --clean --if-exists --no-owner --single-transaction -d "$PGDATABASE" "$file"
echo "restauration OK : $file"
