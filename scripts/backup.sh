#!/usr/bin/env bash
# =============================================================================
# Backup de Indico (produccion): base de datos + archivos (storage fs).
# Pensado para correr en la VPS, desde la raiz del proyecto.
#
#   chmod +x scripts/backup.sh
#   ./scripts/backup.sh
#
# Programar diario con cron (ej. 03:30):
#   30 3 * * * cd /opt/indico-selper && ./scripts/backup.sh >> backups/backup.log 2>&1
# =============================================================================
set -euo pipefail

COMPOSE="docker compose -f docker-compose.prod.yml"
DEST="${BACKUP_DIR:-./backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Cargar credenciales de la DB desde .env
set -a; [ -f .env ] && . ./.env; set +a
PGUSER="${PGUSER:-indico}"
PGDATABASE="${PGDATABASE:-indico}"

mkdir -p "$DEST"

echo "[$(date)] Backup PostgreSQL -> $DEST/db-$STAMP.sql.gz"
$COMPOSE exec -T postgres pg_dump -U "$PGUSER" "$PGDATABASE" | gzip > "$DEST/db-$STAMP.sql.gz"

echo "[$(date)] Backup archivos (volumen indico-archive) -> $DEST/archive-$STAMP.tar.gz"
$COMPOSE exec -T indico tar czf - -C /opt/indico archive > "$DEST/archive-$STAMP.tar.gz"

echo "[$(date)] Limpiando backups de mas de $RETENTION_DAYS dias"
find "$DEST" -name 'db-*.sql.gz'      -mtime +"$RETENTION_DAYS" -delete
find "$DEST" -name 'archive-*.tar.gz' -mtime +"$RETENTION_DAYS" -delete

echo "[$(date)] Backup OK"
