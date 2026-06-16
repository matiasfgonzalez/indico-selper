# Despliegue de Indico en producción (VPS Donweb)

Guía completa para llevar este stack a producción en una VPS de **Donweb**
(o cualquier VPS Linux). Para el entorno **local de pruebas**, ver
[README.md](README.md); aquí solo se cubre producción.

> Resumen del modelo de despliegue:
> Contenedores Docker (Indico + Celery + beat + PostgreSQL + Redis) escuchando
> **solo en loopback**, con **nginx del host** como proxy inverso que termina
> **HTTPS** (Let's Encrypt). El correo se envía por un **SMTP real** (sin Mailpit).

---

## 0. Diferencias local vs. producción

| Aspecto         | Local (`docker-compose.yml`)     | Producción (`docker-compose.prod.yml`)        |
| --------------- | -------------------------------- | --------------------------------------------- |
| Imágenes        | `:latest`                        | Versión fija (`INDICO_IMAGE`, etc. en `.env`) |
| Correo          | Mailpit (captura local)          | SMTP real (`INDICO_SMTP_*`)                    |
| URL             | `http://localhost:8000`          | `https://tu-dominio` (`INDICO_BASE_URL`)      |
| TLS             | No                               | nginx host + Let's Encrypt                    |
| Puerto web      | `0.0.0.0:8000` (abierto)         | `127.0.0.1:8000` (solo proxy lo ve)           |
| `USE_PROXY`     | `False`                          | `True`                                        |
| Secretos        | en claro en `indico.conf`        | en `.env` (fuera de git)                      |
| `restart`       | `unless-stopped`                 | `unless-stopped`                              |

El mismo `data/indico.conf` sirve para ambos: lee todo de variables de entorno
con defaults que reproducen el local. En producción esas variables vienen de `.env`.

---

## 1. Aprovisionar la VPS en Donweb

1. **Plan / recursos.** Indico + PostgreSQL + Redis + Celery consumen memoria.
   Mínimo recomendado: **2 vCPU / 4 GB RAM / 40 GB disco**. Para eventos con
   bastante uso o muchos adjuntos, subir a 8 GB y disco según volumen de archivos.
2. **Sistema operativo:** Ubuntu Server **22.04 o 24.04 LTS** (recomendado).
3. **Acceso SSH:** crear la VPS con clave SSH (no password). Anotar la IP pública.
4. **Snapshots:** activar snapshots/backup del panel de Donweb como red de
   seguridad adicional a los backups de datos (sección 9).

### Consideraciones específicas de Donweb

- **Firewall del panel:** además del firewall del sistema (ufw), Donweb suele
  ofrecer un firewall de red en su panel. Habilitar solo **22 (SSH)**, **80** y
  **443** entrantes.
- **Puerto 25 saliente bloqueado:** la mayoría de los proveedores (Donweb
  incluido) **bloquean el SMTP en el puerto 25** para evitar spam. Por eso en
  `.env` se usa **`INDICO_SMTP_PORT=587`** (submission, con TLS) y autenticación.
  No intentes enviar por el 25.
- **DNS:** si el dominio está administrado en Donweb, crear el registro **A**
  apuntando a la IP de la VPS desde el panel de DNS (sección 3).

---

## 2. Preparar el servidor (una sola vez)

Conectado por SSH como root o con sudo:

```bash
# Actualizar
sudo apt update && sudo apt upgrade -y

# Docker Engine + Compose plugin (script oficial)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER       # re-loguear para aplicar

# Verificar
docker --version
docker compose version

# nginx + certbot (para TLS) y utilidades
sudo apt install -y nginx git
sudo apt install -y certbot python3-certbot-nginx

# Firewall del sistema
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'         # 80 + 443
sudo ufw enable
sudo ufw status
```

---

## 3. DNS

En el panel de DNS (Donweb o donde esté el dominio), crear:

```
Tipo: A    Nombre: eventos    Valor: <IP pública de la VPS>    TTL: 300
```

Esto publica `eventos.tudominio.com`. Verificar la propagación:

```bash
dig +short eventos.tudominio.com    # debe devolver la IP de la VPS
```

No sigas con TLS (sección 6) hasta que el DNS resuelva a la VPS.

---

## 4. Traer el proyecto y configurar `.env`

```bash
sudo mkdir -p /opt/indico-selper
sudo chown $USER:$USER /opt/indico-selper
git clone <URL-de-tu-repo> /opt/indico-selper
cd /opt/indico-selper

cp .env.example .env
```

Editar `.env` y completar **todo**. Generar los secretos:

```bash
# SECRET_KEY (64 hex)
python3 -c "import secrets; print(secrets.token_hex(32))"

# Password de PostgreSQL
openssl rand -base64 24
```

Mínimos a cambiar en `.env`:

- `INDICO_SECRET_KEY` → valor generado (si se filtra o cambia, se invalidan
  sesiones y tokens; **nunca** lo subas a git).
- `PGPASSWORD` → password fuerte.
- `INDICO_BASE_URL` → `https://eventos.tudominio.com`.
- `INDICO_USE_PROXY=true`.
- Bloque `INDICO_SMTP_*` con los datos de tu proveedor de correo.
- `INDICO_IMAGE` → fijar la versión, p. ej. `ghcr.io/indico/indico:3.3`
  (evita que un `latest` rompa el sitio en un redeploy).

> `.env` está en `.gitignore`: no se versiona. Hacé un backup seguro de sus
> valores aparte (gestor de secretos / vault), porque perder `SECRET_KEY` o la
> password de la DB complica la recuperación.

---

## 5. Levantar el stack

```bash
cd /opt/indico-selper
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps
```

En el primer arranque la imagen inicializa el esquema de la base de datos.
Seguí los logs hasta ver que el web quedó escuchando:

```bash
docker compose -f docker-compose.prod.yml logs -f indico
```

Probar que el contenedor responde en loopback (todavía sin nginx/TLS):

```bash
curl -I http://127.0.0.1:8000/    # debe responder con un código HTTP
```

> Si `curl` no responde, revisá los logs: lo más común en el primer boot es la
> base de datos vacía. Los healthchecks ya hacen que Indico espere a que
> PostgreSQL/Redis estén `healthy` antes de arrancar.

---

## 6. nginx + HTTPS (Let's Encrypt)

1. Copiar el server block (ajustá el dominio en el archivo antes o después):

```bash
sudo cp nginx/indico.conf /etc/nginx/sites-available/indico.conf
sudo sed -i 's/eventos.tudominio.com/eventos.TU-DOMINIO-REAL.com/g' \
  /etc/nginx/sites-available/indico.conf
sudo ln -s /etc/nginx/sites-available/indico.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default    # opcional: quitar el default
```

2. **Importante:** el archivo trae el bloque `443` con rutas de certificados que
   **todavía no existen**, así que `nginx -t` fallará. Para el primer
   certificado, dejá que certbot lo gestione:

```bash
# Comentá temporalmente el bloque "server { listen 443 ... }" y el redirect,
# dejando solo el server :80, o usá el modo standalone. Lo más simple:
sudo certbot --nginx -d eventos.TU-DOMINIO-REAL.com
```

`certbot --nginx` obtiene el certificado, escribe las rutas correctas en la
config y agrega el redirect 80→443. Luego:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

3. **Renovación automática:** certbot instala un timer de systemd. Verificar:

```bash
sudo systemctl status certbot.timer
sudo certbot renew --dry-run
```

Visitá `https://eventos.TU-DOMINIO-REAL.com` → debe cargar Indico por HTTPS.

> Tras confirmar que HTTPS funciona, la cabecera `Strict-Transport-Security`
> (HSTS) del server block queda activa. No la actives antes de tener TLS estable.

---

## 7. Bootstrap inicial de Indico

Una vez accesible por HTTPS, entrá a:

```
https://eventos.TU-DOMINIO-REAL.com/bootstrap
```

Ahí se crea el **usuario administrador** y los datos básicos de la instancia
(nombre, organización, zona horaria). Esta página solo está disponible mientras
no exista un admin; después deja de ser accesible.

---

## 8. Correo (SMTP real)

Indico envía confirmaciones, recordatorios y notificaciones vía Celery. Con
`docker-compose.prod.yml` **no hay Mailpit**: se usan las variables `INDICO_SMTP_*`.

- Usá un proveedor con autenticación por **puerto 587 + TLS** (recordá que el 25
  saliente está bloqueado en Donweb).
- Opciones típicas: SMTP del propio proveedor de correo del dominio, o un
  servicio transaccional (SendGrid, Brevo, Amazon SES, Mailgun, etc.).
- Configurar **SPF, DKIM y DMARC** en el DNS del dominio para que los correos no
  caigan en spam.
- Probar el envío después del bootstrap (p. ej. registrándote a un evento o con
  el "test email" del panel de admin) y revisar:

```bash
docker compose -f docker-compose.prod.yml logs -f indico-celery
```

---

## 9. Backups

El stack persiste datos en volúmenes Docker:

- `postgres-data` → base de datos (lo más crítico).
- `indico-archive` → archivos subidos (adjuntos, materiales).
- `indico-custom` → personalizaciones.

Usá el script incluido (hace dump de la DB + tar de los archivos):

```bash
chmod +x scripts/backup.sh
./scripts/backup.sh           # genera backups/db-*.sql.gz y archive-*.tar.gz
```

Programar diario con cron:

```bash
crontab -e
# 03:30 todos los días
30 3 * * * cd /opt/indico-selper && ./scripts/backup.sh >> backups/backup.log 2>&1
```

Restaurar la base de datos:

```bash
gunzip -c backups/db-AAAAMMDD-HHMMSS.sql.gz | \
  docker compose -f docker-compose.prod.yml exec -T postgres psql -U indico -d indico
```

> Llevá copias **fuera de la VPS** (otro servidor, almacenamiento de objetos, o
> los snapshots del panel de Donweb). Un backup solo en la misma VPS no protege
> contra la pérdida del servidor.

---

## 10. Actualizaciones y operación

```bash
# Actualizar a una nueva versión: cambiá INDICO_IMAGE en .env y luego
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d

# La imagen aplica migraciones de DB al arrancar. Hacé backup ANTES de actualizar.

# Ver estado / logs
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f indico

# Reiniciar tras cambios de configuración (indico.conf / .env)
docker compose -f docker-compose.prod.yml up -d --force-recreate \
  indico indico-celery indico-celery-beat

# Entrar a un contenedor
docker compose -f docker-compose.prod.yml exec indico bash
```

> **Probá siempre primero en el entorno local** (`docker-compose.yml`) antes de
> subir un cambio de versión o de config a producción.

---

## 11. Checklist de seguridad para producción

- [ ] `INDICO_SECRET_KEY` único y secreto (no el de ejemplo, no en git).
- [ ] `PGPASSWORD` fuerte y solo en `.env`.
- [ ] `.env` fuera de git (verificado por `.gitignore`).
- [ ] Imágenes con **versión fija**, no `latest`.
- [ ] `INDICO_USE_PROXY=true` y `INDICO_BASE_URL` con `https://`.
- [ ] Contenedores web/DB/Redis **no expuestos** a Internet (solo loopback;
      PostgreSQL y Redis ni siquiera publican puerto).
- [ ] Firewall (ufw **y** panel Donweb): solo 22, 80, 443.
- [ ] TLS válido + renovación automática de certbot probada (`--dry-run`).
- [ ] HSTS activa una vez confirmado HTTPS.
- [ ] SPF/DKIM/DMARC configurados para el correo.
- [ ] Backups automáticos + copia fuera de la VPS, y restore probado.
- [ ] Acceso SSH por clave (password deshabilitado) y, si se puede, puerto SSH
      restringido por IP en el firewall del panel.

---

## 12. Troubleshooting de producción

**El sitio no carga / 502 Bad Gateway en nginx**
- `docker compose -f docker-compose.prod.yml ps` → ¿`indico` está `healthy`?
- `curl -I http://127.0.0.1:8000/` desde la VPS → ¿responde el contenedor?
- Revisar que `upstream` en `nginx/indico.conf` apunte al mismo puerto que
  `INDICO_HTTP_BIND` del `.env` (por defecto `8000`).

**Errores de "mixed content" o enlaces a http**
- Verificar `INDICO_BASE_URL=https://...` y `INDICO_USE_PROXY=true`, y que nginx
  envíe `X-Forwarded-Proto $scheme` (ya está en la plantilla). Recrear los
  contenedores tras cambiar `.env`.

**No se envían correos**
- `docker compose -f docker-compose.prod.yml logs -f indico-celery`.
- Confirmar puerto **587** (no 25), credenciales y TLS correctos en `.env`.

**Subidas grandes fallan (413 Request Entity Too Large)**
- Subir `client_max_body_size` en `nginx/indico.conf` (por defecto `1g`).

**Falta de memoria / contenedores reiniciando**
- `docker stats`; ampliar RAM de la VPS o reducir workers.
```
