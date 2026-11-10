#!/bin/sh
# Sauvegarde de la base dans le volume /backups.
#   sh /scripts/backup.sh       boucle : une sauvegarde toutes les BACKUP_INTERVAL secondes
#   sh /scripts/backup.sh now   une seule sauvegarde, tout de suite
# Connexion : PGHOST (le réplica), PGUSER, PGDATABASE, PGPASSWORD, lues directement par pg_dump.
set -u

dump() {
  # -Fc : format compressé, restaurable table par table ; -Z zstd : plus rapide et compact que gzip.
  pg_dump -h "$1" -Fc -Z zstd -f "$file.tmp"
}

backup() {
  file="/backups/${PGDATABASE}-$(date +%Y%m%d-%H%M%S).dump"

  # Lecture sur le réplica ; s'il est absent, repli sur le primaire.
  # Écriture en .tmp puis renommage : un dump interrompu n'est jamais pris pour une vraie sauvegarde.
  if dump "$PGHOST" || { echo "repli sur le primaire" >&2 && dump db; }; then
    mv "$file.tmp" "$file"
    echo "sauvegarde OK : $file ($(du -h "$file" | cut -f1))"
  else
    rm -f "$file.tmp"
    echo "sauvegarde ÉCHOUÉE" >&2
    return 1
  fi
}

rotate() {
  # On ne garde que les BACKUP_KEEP plus récentes.
  ls -1t /backups/*.dump 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
}

if [ "${1:-}" = "now" ]; then
  backup && rotate
  exit
fi

while :; do
  backup && rotate
  sleep "$BACKUP_INTERVAL"
done
