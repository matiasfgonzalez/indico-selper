# Levantar Indico en desarrollo (local)

Guía paso a paso para clonar el proyecto en cualquier PC y tenerlo corriendo en
local rápido, explicando **qué pasa en cada paso**. Para producción ver
[DEPLOY-PRODUCCION.md](DEPLOY-PRODUCCION.md).

> Este entorno usa `docker-compose.yml` (NO el `.prod.yml`). Trae **Mailpit**
> para capturar el correo en local, la web abierta en `http://localhost:8000` y
> secretos de ejemplo ya incluidos: **no hay que configurar nada** para arrancar.

---

## 1. Requisitos previos

Instalar en la PC nueva:

- **Docker Desktop** (incluye Docker Engine + Docker Compose v2).
  - Windows/Mac: Docker Desktop. Linux: Docker Engine + plugin `docker-compose-v2`.
- **Git** (para clonar).
- Recomendado: **4 GB de RAM** libres para los contenedores.

Verificar que Docker está listo (Docker Desktop debe estar **abierto y corriendo**):

```bash
docker --version          # p. ej. Docker version 28.x
docker compose version    # p. ej. v2.39.x
docker info               # no debe dar error de "cannot connect to the Docker daemon"
```

*Qué pasa:* si `docker info` falla, el motor de Docker no está corriendo →
abrir Docker Desktop y esperar a que diga "Engine running" antes de seguir.

---

## 2. Clonar el proyecto

```bash
git clone <URL-del-repo> indico-selper
cd indico-selper
```

*Qué pasa:* obtenés el repo con `docker-compose.yml`, la carpeta `data/`
(`indico.conf` y `logging.yaml`) y las guías. No hace falta crear ningún `.env`
para desarrollo: el `docker-compose.yml` ya trae los valores locales embebidos.

Estructura mínima que usa el entorno de desarrollo:

```text
indico-selper/
├─ docker-compose.yml      # stack de desarrollo
└─ data/
   ├─ indico.conf          # config (lee env con defaults locales)
   └─ logging.yaml         # logging
```

---

## 3. Levantar el stack

```bash
docker compose up -d
```

*Qué pasa, en orden:*

1. **Descarga de imágenes** (solo la primera vez): `ghcr.io/indico/indico`,
   `postgres:15`, `redis:7`, `axllent/mailpit`. La de Indico es grande (cientos
   de MB), así que el primer `up` puede tardar varios minutos. Las siguientes
   veces ya están en caché y arranca en segundos.
2. **Crea volúmenes y red.** Se crean los volúmenes nombrados
   (`postgres-data`, `indico-archive`, etc.) donde quedan los datos persistentes,
   y una red interna para que los contenedores se vean por nombre
   (`postgres`, `redis`, `mailpit`).
3. **Arranque ordenado.** Gracias a los *healthchecks*, primero levantan
   `postgres`, `redis` y `mailpit`; recién cuando PostgreSQL y Redis están
   `healthy`, arrancan `indico`, `indico-celery` e `indico-celery-beat`. Esto
   evita el clásico error de que Indico intente conectar a una base de datos que
   todavía no está lista.
4. **Inicialización de la base de datos** (solo la primera vez): la imagen de
   Indico prepara el esquema automáticamente en el primer arranque. Esto tarda
   un poco; hasta que termina, la web puede dar error 500 (es normal al inicio).

Ver el estado:

```bash
docker compose ps
```

Esperás algo así (los tres de infraestructura en `healthy`):

```
SERVICE              STATUS
indico               Up (running)
indico-celery        Up (running)
indico-celery-beat   Up (running)
mailpit              Up (healthy)
postgres             Up (healthy)
redis                Up (healthy)
```

Seguir el arranque de la web hasta que esté lista:

```bash
docker compose logs -f indico
```

*Qué buscar:* la línea `uwsgi socket 0 bound to TCP address 0.0.0.0:59999`
indica que el servidor web ya escucha (Ctrl+C corta el seguimiento de logs, no
apaga el contenedor).

---

## 4. Primer uso: bootstrap del administrador

Abrir en el navegador:

```
http://localhost:8000/bootstrap
```

*Qué pasa:* es el asistente de **primer arranque** de Indico. Ahí se crea el
**usuario administrador** y los datos básicos de la instancia (nombre,
organización, zona horaria, email). Una vez creado el admin, esta página deja de
estar disponible y entrás por `http://localhost:8000`.

> Si `/bootstrap` da error 500 al toque de levantar, esperá entre 30 y 60
> segundos (la DB todavía se está inicializando) y recargá. Si persiste, mirá
> los logs: `docker compose logs indico` (ver Troubleshooting).

---

## 5. URLs útiles en desarrollo

| Servicio              | URL                              | Para qué                         |
| --------------------- | -------------------------------- | -------------------------------- |
| Indico (web)          | `http://localhost:8000`          | La aplicación                    |
| Bootstrap (1ª vez)    | `http://localhost:8000/bootstrap`| Crear el admin inicial           |
| Mailpit (UI de mails) | `http://localhost:8025`          | Ver TODOS los correos capturados |

*Qué pasa con el correo:* en desarrollo **no se envía correo real**. Indico lo
manda al contenedor Mailpit (SMTP en `mailpit:1025`), y lo ves en su interfaz
web (`http://localhost:8025`). Ideal para probar registros, confirmaciones y
recordatorios sin spamear a nadie.

---

## 6. Comandos del día a día

```bash
# Encender / apagar (conservando datos)
docker compose up -d            # levantar
docker compose stop             # apagar contenedores (los datos quedan)
docker compose start            # volver a encender

# Ver logs
docker compose logs -f indico
docker compose logs -f indico-celery     # tareas en background (envío de mails, etc.)

# Entrar a un contenedor
docker compose exec indico bash

# Reiniciar tras tocar data/indico.conf o data/logging.yaml
docker compose up -d --force-recreate indico indico-celery indico-celery-beat
```

*Qué pasa:* `data/indico.conf` y `data/logging.yaml` se montan dentro de los
contenedores. Si los editás, hay que **recrear** los servicios de Indico para
que tomen los cambios (un simple `restart` también suele alcanzar).

---

## 7. Resetear el entorno (empezar de cero)

```bash
docker compose down       # baja contenedores y red; CONSERVA los volúmenes/datos
docker compose down -v    # ⚠️ baja TODO y BORRA los volúmenes: DB, archivos, colas
```

*Qué pasa:* usá `down -v` cuando querés una instalación limpia (vuelve a pedir
`/bootstrap`). Es destructivo: borra la base de datos y los archivos subidos.

---

## 8. Resumen ultra rápido (PC ya con Docker)

```bash
git clone <URL-del-repo> indico-selper
cd indico-selper
docker compose up -d
# esperar ~1-2 min la primera vez, luego abrir:
#   http://localhost:8000/bootstrap   (crear admin)
#   http://localhost:8025             (correos de prueba)
```

---

## 9. Troubleshooting

**El primer `up` tarda muchísimo / parece colgado**
- Está descargando la imagen de Indico (grande). Mirá el progreso con
  `docker compose logs -f` o el panel de Docker Desktop. Es normal la 1ª vez.

**`http://localhost:8000` da 500 al recién levantar**
- La base de datos se está inicializando. Esperá 30-60 s y recargá.
- Si sigue, revisá: `docker compose logs indico`. Un `NameError`/traceback de
  Python al cargar `indico.conf` indica un error en ese archivo de config.

**"port is already allocated" / 8000 u 8025 ocupado**
- Otro proceso usa el puerto. Cambiá el mapeo en `docker-compose.yml`
  (p. ej. `"8080:59999"`) y reabrí en esa URL. Recordá que la web interna
  escucha en `59999`; solo cambia el puerto del **host** (lado izquierdo).

**"cannot connect to the Docker daemon"**
- Docker Desktop no está corriendo. Abrilo y esperá a "Engine running".

**Los correos no aparecen en Mailpit**
- Confirmá `docker compose ps` con `mailpit` en `healthy`.
- El envío lo hace el worker: `docker compose logs -f indico-celery`.

**Cambié `data/indico.conf` y no se refleja**
- Recreá los servicios: 
  `docker compose up -d --force-recreate indico indico-celery indico-celery-beat`.

**Quiero empezar de cero**
- `docker compose down -v` y volver a `docker compose up -d`.
