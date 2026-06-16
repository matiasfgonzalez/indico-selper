# Indico Selper - Stack local con Docker Compose

Proyecto base para ejecutar **Indico** en entorno local con:

- Aplicación web Indico
- Worker Celery
- Scheduler Celery Beat
- PostgreSQL
- Redis
- Mailpit (captura de emails local)

Este repositorio está orientado a desarrollo/pruebas locales.

## 1. Arquitectura del proyecto

### Servicios

| Servicio             | Imagen                         | Rol                         | Puerto host                |
| -------------------- | ------------------------------ | --------------------------- | -------------------------- |
| `indico`             | `ghcr.io/indico/indico:latest` | Web app (uWSGI)             | `8000`                     |
| `indico-celery`      | `ghcr.io/indico/indico:latest` | Worker de tareas asíncronas | -                          |
| `indico-celery-beat` | `ghcr.io/indico/indico:latest` | Scheduler periódico         | -                          |
| `postgres`           | `postgres:15`                  | Base de datos               | -                          |
| `redis`              | `redis:7`                      | Broker/cache                | -                          |
| `mailpit`            | `axllent/mailpit:latest`       | SMTP local y UI de correos  | `8025` (UI), `1025` (SMTP) |

### Flujo principal

1. Usuario accede a Indico por `http://localhost:8000`.
2. Indico persiste datos en PostgreSQL.
3. Tareas (emails, recordatorios, procesos en background) se encolan en Redis.
4. `indico-celery` consume tareas y las ejecuta.
5. `indico-celery-beat` dispara tareas programadas.
6. Correos se envían a Mailpit (captura local, no envío real a internet).

## 2. Estructura del repositorio

```text
indico-selper/
├─ docker-compose.yml
└─ data/
   ├─ indico.conf
   └─ logging.yaml
```

## 3. Requisitos

- Docker Desktop (o motor Docker compatible)
- Docker Compose v2 (`docker compose`)
- Recomendado: al menos 4 GB RAM disponibles para contenedores

## 4. Puesta en marcha

### Levantar todo el stack

```bash
docker compose up -d
```

### Ver estado

```bash
docker compose ps
```

### URLs útiles

- Indico: `http://localhost:8000`
- Bootstrap inicial de Indico (primera vez): `http://localhost:8000/bootstrap`
- Mailpit UI: `http://localhost:8025`

## 5. Configuración técnica

## 5.1 docker-compose.yml

Puntos clave de la configuración actual:

- Se usa `command: /opt/indico/run_indico.sh` para web.
- Celery y beat usan `run_celery.sh`.
- Se montan archivos de configuración en modo readonly:
  - `./data/indico.conf -> /opt/indico/etc/indico.conf`
  - `./data/logging.yaml -> /opt/indico/etc/logging.yaml`
- Se usan volúmenes nombrados para persistencia de datos y logs.
- Se configuró `tmpfs` para:
  - `/opt/indico/tmp`
  - `/var/cache/fontconfig`
    Esto reduce warnings de font cache en runtime.

## 5.2 data/indico.conf

Configuraciones relevantes:

- DB: `SQLALCHEMY_DATABASE_URI` con variables `PG*` del compose.
- Redis:
  - `REDIS_CACHE_URL = redis://redis:6379/0`
  - `CELERY_BROKER = redis://redis:6379/1`
- Email local con Mailpit:
  - `SMTP_SERVER = ('mailpit', 1025)`
  - TLS/SSL desactivado para entorno local
- Directorios de ejecución/persistencia:
  - `LOG_DIR`, `TEMP_DIR`, `CACHE_DIR`, `CUSTOMIZATION_DIR`
- Storage de archivos:
  - `STORAGE_BACKENDS = {'default': 'fs:/opt/indico/archive'}`

## 5.3 data/logging.yaml

- Logging con `dictConfig` de Python.
- Niveles:
  - root en `INFO`
  - otros logs en `WARNING`
- Formatos:
  - texto legible
  - JSON por línea
- Destinos:
  - consola (`stderr_text`)
  - archivos rotativos en `/opt/indico/log`

Archivos generados típicos:

- `/opt/indico/log/indico.log`
- `/opt/indico/log/indico.json.log`
- `/opt/indico/log/celery.log`
- `/opt/indico/log/celery.json.log`
- `/opt/indico/log/other.log`

## 6. Persistencia

Volúmenes definidos:

- `postgres-data`: datos de PostgreSQL
- `redis-data`: datos de Redis
- `indico-archive`: storage de archivos de Indico
- `indico-custom`: personalizaciones
- `indico-static`: estáticos compartidos
- `indico-log`: logs
- `indico-cache`: cache

## 7. Comandos operativos (cheat sheet)

### Arranque/parada

```bash
docker compose up -d
docker compose stop
docker compose down
```

### Reiniciar servicios críticos

```bash
docker compose restart indico indico-celery indico-celery-beat
```

### Ver logs

```bash
docker compose logs -f
docker compose logs -f indico
docker compose logs -f indico-celery
docker compose logs -f indico-celery-beat
docker compose logs -f mailpit
```

### Entrar a contenedor

```bash
docker compose exec indico sh
docker compose exec indico-celery sh
```

### Validar configuración compose

```bash
docker compose config
```

### Forzar recreación tras cambios de config

```bash
docker compose up -d --force-recreate
```

### Ver correos capturados por API de Mailpit

```bash
curl http://localhost:8025/api/v1/messages
```

## 8. Troubleshooting

### 8.1 Error: "/opt/indico/docker_entrypoint.sh: no such file or directory"

Causa común:

- Se montó una carpeta host sobre todo `/opt/indico`.

Solución:

- No montar `./data:/opt/indico`.
- Montar solo rutas puntuales (como está actualmente en este proyecto).

### 8.2 Correos no aparecen en Mailpit

Checklist:

1. `docker compose ps` muestra `mailpit` en `healthy`.
2. `data/indico.conf` tiene `SMTP_SERVER = ('mailpit', 1025)`.
3. Reiniciar servicios de Indico tras cambios:
   - `docker compose restart indico indico-celery indico-celery-beat`
4. Revisar logs del worker:
   - `docker compose logs -f indico-celery`

Nota:

- Reintentos de correos viejos pueden seguir apareciendo un tiempo si fueron encolados antes del cambio de SMTP.

### 8.3 Warning de Fontconfig

Si aparece `Fontconfig error: No writable cache directories`:

- Verificar `tmpfs` en compose para `/opt/indico/tmp` y `/var/cache/fontconfig`.
- Reiniciar contenedores tras cambios.

### 8.4 Warning de uWSGI sobre harakiri/post buffering

- En local no suele ser bloqueante.
- En producción conviene ajustar buffering/timeouts en proxy (Nginx/Traefik) y uWSGI.

## 9. Backups (mínimo recomendado)

### Backup PostgreSQL

```bash
docker compose exec -T postgres pg_dump -U indico indico > backup_indico.sql
```

### Restore PostgreSQL

```bash
cat backup_indico.sql | docker compose exec -T postgres psql -U indico -d indico
```

## 10. Limpieza y reseteo

### Bajar stack y eliminar contenedores/red

```bash
docker compose down
```

### Borrado total incluyendo volúmenes (destructivo)

```bash
docker compose down -v
```

Esto elimina base de datos, colas, archivos y estado persistido.

## 11. Consideraciones de seguridad y producción

Este setup está pensado para local. Para producción:

- No usar `latest`; fijar tags/versiones.
- Cambiar `SECRET_KEY` por uno seguro y no versionarlo.
- Configurar SMTP real (`SMTP_SERVER`, `SMTP_LOGIN`, `SMTP_PASSWORD`, TLS/SSL).
- Poner proxy inverso con TLS.
- Ajustar `BASE_URL`/`USE_PROXY` según despliegue real.
- Definir estrategia formal de backups y retención de logs.
- Separar entornos (dev/staging/prod) y secretos.

## 12. Estado actual del proyecto

- Stack Docker funcional en local.
- Logging estructurado y rotativo activo.
- Captura de emails local con Mailpit habilitada.
- Servicio web disponible en `http://localhost:8000`.
- Correo de desarrollo visible en `http://localhost:8025`.
