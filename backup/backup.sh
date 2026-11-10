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
  pg_dump -h "$1" -Fc -Z zstd -f "$tmp" && source=$1
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

# Journal affiché sur la page Infrastructure. S'il échoue, la sauvegarde reste valide.
record() {
  psql -h db -qX -v ON_ERROR_STOP=1 \
    -v file="$(basename "$file")" -v size="$(stat -c %s "$file")" -v source="$source" \
    -v kept="$(find "$dir" -name '*.dump' | wc -l)" <<'SQL' || echo "sauvegarde non inscrite dans le journal" >&2
INSERT INTO backup_log (file, size_bytes, source, kept) VALUES (:'file', :size, :'source', :kept);
DELETE FROM backup_log WHERE id <= (SELECT max(id) - 100 FROM backup_log);
SQL
}

if [ "${1:-}" = now ]; then
  backup && rotate && record
  exit
fi

trap 'exit 0' TERM INT

while :; do
  backup && rotate && record
  sleep "$BACKUP_INTERVAL" &
  wait $!
done
