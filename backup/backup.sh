#!/bin/sh
# Usage : backup.sh        sauvegarde toutes les BACKUP_INTERVAL secondes
#         backup.sh now    une seule sauvegarde
set -u

PGPASSWORD="$(tr -d '\r\n' < /run/secrets/db_password)"
export PGPASSWORD

dir=/var/lib/postgresql/backups
umask 077
mkdir -p "$dir"

dump() {
  pg_dump -h "$1" -Fc -Z zstd -f "$tmp"
}

backup() {
  file="$dir/$PGDATABASE-$(date +%Y%m%d-%H%M%S).dump"
  tmp="$file.tmp"

  if dump "$PGHOST" || { echo "réplica indisponible, sauvegarde depuis db" >&2; dump db; }; then
    mv "$tmp" "$file"
    echo "sauvegarde OK : $file"
  else
    rm -f "$tmp"
    echo "sauvegarde échouée" >&2
    return 1
  fi
}

rotate() {
  find "$dir" -name '*.dump' | sort -r | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
}

if [ "${1:-}" = now ]; then
  backup && rotate
  exit
fi

trap 'exit 0' TERM INT

while :; do
  backup && rotate
  sleep "$BACKUP_INTERVAL" &
  wait $!
done
