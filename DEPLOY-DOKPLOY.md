# Despliegue con Dokploy: landing (`matudev.com.ar`) + Indico (`indico.matudev.com.ar`)

Guía completa y paso a paso para, en **una sola VPS**:

- Comprar el dominio **`matudev.com.ar`** y configurar su DNS.
- Instalar **Docker + Dokploy** (que trae **Traefik** como reverse proxy con HTTPS automático).
- Publicar una **landing** en `https://matudev.com.ar` (y `www`).
- Publicar **Indico** en `https://indico.matudev.com.ar`.
- Endurecer el servidor (hardening), backups, logs y recuperación ante desastre.

> Esta guía **reemplaza** el modelo de `DEPLOY-PRODUCCION.md` (nginx del host + certbot).
> Con Dokploy, **Traefik** hace de proxy inverso y gestiona los certificados TLS por vos.
> No instales nginx ni certbot en el host: chocarían con Traefik por los puertos 80/443.

---

## Índice

1. [Esquema de arquitectura](#1-esquema-de-arquitectura)
2. [Requisitos previos](#2-requisitos-previos)
3. [Comprar el dominio `matudev.com.ar`](#3-comprar-el-dominio-matudevcomar)
4. [Configurar el DNS](#4-configurar-el-dns)
5. [Aprovisionar la VPS](#5-aprovisionar-la-vps)
6. [Hardening del servidor](#6-hardening-del-servidor)
7. [Instalar Docker](#7-instalar-docker)
8. [Instalar Dokploy](#8-instalar-dokploy)
9. [Traefik: cómo enruta y dónde se toca](#9-traefik-cómo-enruta-y-dónde-se-toca)
10. [Proyecto landing (`matudev.com.ar`)](#10-proyecto-landing-matudevcomar)
11. [Proyecto Indico (`indico.matudev.com.ar`)](#11-proyecto-indico-indicomatudevcomar)
12. [Certificados HTTPS](#12-certificados-https)
13. [Variables del `.env`](#13-variables-del-env)
14. [Logs](#14-logs)
15. [Backups](#15-backups)
16. [Recuperación ante desastre y restauración completa](#16-recuperación-ante-desastre-y-restauración-completa)
17. [Checklist previo a producción](#17-checklist-previo-a-producción)
18. [Troubleshooting](#18-troubleshooting)

---

## 1. Esquema de arquitectura

Una VPS con Docker. **Dokploy** administra todo desde un panel web; **Traefik**
(desplegado por Dokploy) escucha en los puertos 80/443 públicos y enruta según el
dominio (Host) hacia el contenedor correcto. Solo Traefik está expuesto a Internet.

```
                              Internet
                                 │
                 matudev.com.ar / www / indico.*
                                 │  DNS (registros A)  ──► IP pública VPS
                                 ▼
        ┌───────────────────────────────────────────────────────┐
        │                        VPS (Ubuntu)                     │
        │                                                         │
        │   ufw: solo 22, 80, 443 (panel 3000 restringido)        │
        │                                                         │
        │   ┌───────────────── Traefik (Dokploy) ──────────────┐  │
        │   │   :80  ──redirect──►  :443 (TLS Let's Encrypt)    │  │
        │   └───────┬───────────────────────────┬──────────────┘  │
        │           │ Host=matudev.com.ar        │ Host=indico.*   │
        │           ▼                            ▼                 │
        │   ┌───────────────┐        ┌───────────────────────┐    │
        │   │   landing     │        │   indico (web :59999) │    │
        │   │ (nginx static)│        └──────────┬────────────┘    │
        │   └───────────────┘                   │ red interna     │
        │                          ┌────────────┼────────────┐    │
        │                          ▼            ▼            ▼    │
        │                    ┌──────────┐ ┌─────────┐ ┌──────────┐│
        │                    │ postgres │ │  redis  │ │  celery  ││
        │                    └──────────┘ └─────────┘ │  + beat  ││
        │                                             └──────────┘│
        │           red "dokploy-network"  ◄── Traefik ⇄ web       │
        │           red "indico-internal"  ◄── web ⇄ db/redis/celery│
        └───────────────────────────────────────────────────────┘
```

Puntos clave:

- **Traefik** es el único que publica puertos (80/443). Ningún otro contenedor abre puertos al host.
- **Indico web** se conecta a dos redes: `dokploy-network` (para que Traefik lo alcance)
  e `indico-internal` (para hablar con Postgres/Redis/Celery).
- **Postgres, Redis y Celery** solo viven en `indico-internal`: **no** son accesibles desde Internet.
- La **landing** es un contenedor aparte (nginx con archivos estáticos) que Traefik publica en el dominio raíz.
- El panel de **Dokploy** (puerto 3000) queda **restringido** por firewall (o detrás de su propio subdominio con login).

---

## 2. Requisitos previos

**Cuentas y accesos:**

- Cuenta en un **registrador de dominios `.com.ar`** (ver §3).
- Cuenta en un **proveedor de VPS** (Donweb, Hetzner, DigitalOcean, Contabo, etc.).
- Una **clave SSH** (par pública/privada). Generar en tu máquina si no tenés:
  ```bash
  ssh-keygen -t ed25519 -C "matudev-vps"
  ```
- Un **cliente de correo SMTP** para Indico (SMTP del proveedor del dominio o transaccional:
  Brevo, SendGrid, Amazon SES, Mailgun…). Necesario para que Indico mande notificaciones.

**Recursos de la VPS (mínimos para landing + Indico + Dokploy):**

| Recurso | Mínimo | Recomendado |
| ------- | ------ | ----------- |
| vCPU    | 2      | 2–4         |
| RAM     | 4 GB   | 8 GB        |
| Disco   | 40 GB  | 60–80 GB (según adjuntos) |
| SO      | Ubuntu Server 22.04 / 24.04 LTS | 24.04 LTS |

> Dokploy pide **mínimo 2 GB de RAM** solo para sí mismo; Indico (web + celery + beat + Postgres
> + Redis) suma bastante. Por eso el mínimo realista de este combo es **4 GB**.

**Conocimientos:** manejo básico de SSH y línea de comandos Linux. No hace falta saber nginx:
Dokploy/Traefik lo abstraen.

---

## 3. Comprar el dominio `matudev.com.ar`

Los dominios **`.com.ar`** se registran a través de **NIC Argentina** (https://nic.ar),
o mediante un **registrador habilitado** que opera contra NIC.ar (Donweb, Nube.ar, Neubox, etc.).

Pasos:

1. Entrá a **https://nic.ar** e ingresá con **AFIP (Clave Fiscal)** o creá tu usuario.
   El registro `.com.ar` requiere identidad argentina (CUIT/CUIL).
2. Buscá **`matudev.com.ar`** y verificá que esté disponible.
3. Registralo y pagalo (el `.com.ar` es anual). Al confirmarse, el dominio queda a tu nombre.
4. Definí quién administra el **DNS**:
   - **Opción A (recomendada, más simple):** usar los **nameservers del proveedor de la VPS**
     (si ofrece zona DNS) o un DNS gratuito como **Cloudflare**. Cargás ahí los registros del §4.
   - **Opción B:** usar el **panel DNS de NIC.ar** directamente y cargar los registros ahí.

> **Cloudflare (opcional pero cómodo):** creás una cuenta gratis, agregás `matudev.com.ar`,
> Cloudflare te da 2 nameservers, y los cargás en NIC.ar (sección "Delegaciones"/DNS).
> Luego administrás los registros A desde Cloudflare. Si lo usás, poné los registros en
> modo **"DNS only" (nube gris)** al principio, no proxy (nube naranja), para que Let's Encrypt
> valide sin problemas. Una vez andando podés activar el proxy.

Tiempo de propagación de la delegación de nameservers: desde minutos hasta 24–48 h.

---

## 4. Configurar el DNS

Necesitás que **tres nombres** apunten a la **IP pública de la VPS** (la obtenés en §5;
podés registrar el dominio antes y volver acá cuando tengas la IP).

En el panel DNS (NIC.ar, el del proveedor, o Cloudflare) creá:

| Tipo  | Nombre (host) | Valor            | TTL |
| ----- | ------------- | ---------------- | --- |
| A     | `@`           | `IP_DE_LA_VPS`   | 300 |
| A     | `www`         | `IP_DE_LA_VPS`   | 300 |
| A     | `indico`      | `IP_DE_LA_VPS`   | 300 |
| A     | `dokploy`     | `IP_DE_LA_VPS`   | 300 |

- `@` = el dominio raíz `matudev.com.ar`.
- `www` = `www.matudev.com.ar`.
- `indico` = `indico.matudev.com.ar`.
- `dokploy` = `dokploy.matudev.com.ar` (panel de administración de Dokploy; ver §8).

> Alternativa: un registro **wildcard** `A  *  IP_DE_LA_VPS` cubre cualquier subdominio de una,
> pero es más explícito y seguro declarar solo los que usás.

Verificar la propagación (desde tu máquina):

```bash
dig +short matudev.com.ar
dig +short www.matudev.com.ar
dig +short indico.matudev.com.ar
dig +short dokploy.matudev.com.ar
# Los cuatro deben devolver la IP de la VPS.
```

**No sigas con los certificados HTTPS (§12) hasta que los tres nombres resuelvan a la VPS.**
Let's Encrypt valida por HTTP contra el dominio: si el DNS no apunta bien, la emisión falla.

---

## 5. Aprovisionar la VPS

1. Creá la VPS con **Ubuntu Server 22.04/24.04 LTS** y los recursos del §2.
2. Al crearla, cargá tu **clave SSH pública** (no uses password).
3. Anotá la **IP pública** → cargala en los registros del §4.
4. Si el proveedor ofrece **firewall de red en el panel** (Donweb, DO, Hetzner Cloud),
   dejá entrantes solo: **22 (SSH)**, **80 (HTTP)** y **443 (HTTPS)**.
   El **3000** (panel Dokploy) **no** lo abras a todo Internet (ver §6 y §8).
5. Si el proveedor ofrece **snapshots/backup**, activalos: son tu red de seguridad de bajo nivel
   además de los backups de datos (§15).

Conectate:

```bash
ssh root@IP_DE_LA_VPS      # o el usuario que dé el proveedor
```

> **Nota Donweb / puerto 25:** la mayoría de los proveedores bloquean el **SMTP saliente por
> el puerto 25**. Por eso Indico usa **587 + TLS** (ver §13). No intentes enviar por el 25.

---

## 6. Hardening del servidor

Hacerlo **antes** de exponer servicios. Conectado por SSH:

**a) Crear un usuario sudo (no operar como root):**

```bash
adduser matias
usermod -aG sudo matias
# Copiar tu clave SSH al nuevo usuario:
rsync --archive --chown=matias:matias ~/.ssh /home/matias
```

Probá en **otra terminal** que podés entrar como `matias` antes de cerrar la de root:

```bash
ssh matias@IP_DE_LA_VPS
```

**b) Endurecer SSH.** Editá `/etc/ssh/sshd_config` (con `sudo`) y dejá:

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

Aplicar:

```bash
sudo systemctl restart ssh
```

**c) Firewall (ufw):**

```bash
sudo apt update
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH            # 22
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
# Panel Dokploy (3000): NO abrir a todos. Elegí UNA opción:
#   Opción segura A: no abrirlo y acceder por túnel SSH (ver §8).
#   Opción B: permitir solo tu IP fija:
# sudo ufw allow from TU_IP_FIJA to any port 3000 proto tcp
sudo ufw enable
sudo ufw status verbose
```

**d) Actualizaciones automáticas de seguridad:**

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # responder "Yes"
```

**e) Fail2ban (bloquea fuerza bruta de SSH):**

```bash
sudo apt install -y fail2ban
sudo systemctl enable --now fail2ban
```

**f) Zona horaria (opcional):**

```bash
sudo timedatectl set-timezone America/Argentina/Buenos_Aires
```

> Regla general: **cuanto menos puertos abiertos, mejor.** Traefik solo necesita 80 y 443.
> El panel de Dokploy es la superficie más sensible: manténlo cerrado o detrás de tu IP.

---

## 7. Instalar Docker

Dokploy necesita Docker. El **instalador de Dokploy (§8) instala Docker si falta**, pero podés
hacerlo explícito con el script oficial:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER      # re-logueá la sesión SSH para aplicar
docker --version
docker compose version
```

> Dokploy trabaja con **Docker en modo Swarm** (para Traefik y los servicios). Su instalador
> inicializa el swarm automáticamente; no hace falta que lo hagas a mano.

---

## 8. Instalar Dokploy

Con Docker instalado y el firewall configurado, instalá Dokploy (como root o con sudo):

```bash
curl -sSL https://dokploy.com/install.sh | sudo sh
```

El script:

- Instala Docker si falta e inicializa **Docker Swarm**.
- Crea la red **`dokploy-network`** (la usan los servicios para hablar con Traefik).
- Levanta **Traefik** (proxy 80/443) y el **panel de Dokploy** en el puerto **3000**.

**Acceder al panel:**

- Si abriste el 3000 solo a tu IP (§6, opción B):
  `http://IP_DE_LA_VPS:3000`
- Si lo dejaste cerrado (opción A, recomendada), abrí un **túnel SSH** desde tu máquina:
  ```bash
  ssh -L 3000:localhost:3000 matias@IP_DE_LA_VPS
  ```
  y entrá a `http://localhost:3000` en tu navegador.

En el primer ingreso creás el **usuario administrador** del panel. Hacelo cuanto antes:
mientras no exista admin, cualquiera que llegue al 3000 puede crearlo.

### 8.1. Asignar `dokploy.matudev.com.ar` al panel (paso a paso)

Objetivo: dejar de acceder por `IP:3000` y entrar al panel por `https://dokploy.matudev.com.ar`
con certificado válido. Traefik (ya corriendo) publica el propio panel de Dokploy.

**Requisito previo:** el registro A `dokploy` → IP de la VPS ya creado y propagado (§4). Verificá:

```bash
dig +short dokploy.matudev.com.ar    # debe devolver la IP de la VPS
```

**Pasos en el panel:**

1. Entrá al panel (por túnel SSH o `IP:3000`, como en §8) y logueate como admin.
2. Andá a **Settings → Server** (según versión, "Web Server" / "Web Domain").
3. En **Domain**, cargá: `dokploy.matudev.com.ar`.
4. En **HTTPS**, activá **Let's Encrypt** y cargá un **email** válido (para avisos del certificado).
5. Guardá / aplicá. Dokploy reconfigura Traefik: crea el router del panel para ese Host y pide el
   certificado. Esperá unos segundos a que emita.
6. Abrí **`https://dokploy.matudev.com.ar`** → debe cargar el panel por HTTPS con candado válido.

**Cerrar el puerto 3000 una vez que el subdominio funciona** (ya no hace falta exponerlo):

```bash
# Si lo habías abierto a tu IP (§6 opción B), quitá esa regla:
sudo ufw status numbered          # ver el número de la regla del 3000
sudo ufw delete <NUMERO>          # borrar la regla del puerto 3000
sudo ufw status verbose
```

Desde ahí, el acceso al panel es solo por `https://dokploy.matudev.com.ar` (con login) y, como
respaldo, por túnel SSH. El 3000 deja de estar expuesto a Internet.

> Si el certificado del panel no emite, es la misma causa que en §12/§18: DNS sin propagar o
> puerto 80 cerrado. Corregí eso y reintentá desde Settings.

---

## 9. Traefik: cómo enruta y dónde se toca

**No instalás ni configurás Traefik a mano.** Dokploy lo despliega y lo gestiona. Traefik decide
a qué contenedor mandar cada request según el **dominio (Host)** y unas **labels** de Docker.

Hay dos formas de decirle a Traefik "este dominio va a este servicio":

1. **Pestaña "Domains" del panel de Dokploy** (la más simple): elegís el servicio, el puerto
   interno y el dominio; Dokploy inyecta las labels de Traefik y pide el certificado. Es la que
   usaremos para la **landing** (§10).
2. **Labels de Traefik en el `docker-compose`** (explícito y portable): las escribís vos en el
   YAML. Es la que trae `docker-compose.dokploy.yml` para **Indico** (§11), porque deja la
   configuración versionada en el repo.

Datos que usa Dokploy por defecto y que vas a ver referenciados:

- **Entrypoints:** `web` (puerto 80) y `websecure` (puerto 443).
- **Cert resolver:** `letsencrypt` (emite y renueva los certificados solo).
- **Red:** `dokploy-network` (el servicio debe estar conectado a ella para que Traefik lo vea).

---

## 10. Proyecto landing (`matudev.com.ar`)

La landing es un sitio estático servido por **nginx**. La forma más simple y controlada es un
proyecto Compose con tu `index.html`.

**a) En el panel de Dokploy:** creá un **Project** (p. ej. `matudev`) y dentro un servicio
tipo **Compose** llamado `landing`. Podés apuntarlo a un repo Git con estos archivos, o pegar
el Compose directo.

**b) Estructura del proyecto landing** (repo o carpeta):

```
landing/
├── docker-compose.yml
└── site/
    └── index.html
```

`landing/site/index.html` (ejemplo mínimo — reemplazá por tu diseño real):

```html
<!doctype html>
<html lang="es">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Matudev</title>
  </head>
  <body>
    <h1>Matudev</h1>
    <p>Bienvenido. <a href="https://indico.matudev.com.ar">Ir a Indico →</a></p>
  </body>
</html>
```

`landing/docker-compose.yml`:

```yaml
services:
  landing:
    image: nginx:1.27-alpine
    restart: unless-stopped
    volumes:
      - ./site:/usr/share/nginx/html:ro
    networks:
      - dokploy-network
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=dokploy-network"
      # HTTP -> redirect a HTTPS
      - "traefik.http.routers.landing-web.rule=Host(`matudev.com.ar`) || Host(`www.matudev.com.ar`)"
      - "traefik.http.routers.landing-web.entrypoints=web"
      - "traefik.http.routers.landing-web.middlewares=landing-redirect-https"
      - "traefik.http.middlewares.landing-redirect-https.redirectscheme.scheme=https"
      # HTTPS
      - "traefik.http.routers.landing-secure.rule=Host(`matudev.com.ar`) || Host(`www.matudev.com.ar`)"
      - "traefik.http.routers.landing-secure.entrypoints=websecure"
      - "traefik.http.routers.landing-secure.tls=true"
      - "traefik.http.routers.landing-secure.tls.certresolver=letsencrypt"
      - "traefik.http.services.landing.loadbalancer.server.port=80"

networks:
  dokploy-network:
    external: true
```

**c) Deploy:** en Dokploy, en el servicio `landing`, hacé **Deploy**. Traefik detecta las labels,
pide el certificado para `matudev.com.ar` y `www.matudev.com.ar`, y publica el sitio.

> **Alternativa sin escribir labels:** en vez del Compose con labels, creá el servicio y usá la
> pestaña **Domains → Add Domain** (Host `matudev.com.ar`, container port `80`, HTTPS + Let's
> Encrypt, redirect HTTP→HTTPS activado). Dokploy hace lo mismo desde la UI.

Verificar: `https://matudev.com.ar` debe cargar tu HTML por HTTPS.

---

## 11. Proyecto Indico (`indico.matudev.com.ar`)

Este repo ya trae **`docker-compose.dokploy.yml`**: es el stack de producción adaptado a Dokploy
(sin publicar puertos; Traefik enruta por labels; Postgres/Redis/Celery en red interna privada).

**a) Traer el repo a la VPS** (o conectarlo por Git en Dokploy). Por SSH:

```bash
sudo mkdir -p /opt/indico-selper
sudo chown $USER:$USER /opt/indico-selper
git clone <URL-de-tu-repo> /opt/indico-selper
cd /opt/indico-selper
cp .env.example .env
```

**b) Completar `.env`** (ver §13 para el detalle). Mínimo a cambiar:

- `INDICO_SECRET_KEY` → generá con `python3 -c "import secrets; print(secrets.token_hex(32))"`
- `PGPASSWORD` → generá con `openssl rand -base64 24`
- `INDICO_BASE_URL=https://indico.matudev.com.ar`
- `INDICO_USE_PROXY=true`
- Bloque `INDICO_SMTP_*` con tu proveedor de correo (puerto **587**).
- `INDICO_IMAGE` con versión fija (p. ej. `ghcr.io/indico/indico:3.3`).

**c) Crear el servicio en Dokploy:** en el Project `matudev`, agregá un servicio tipo **Compose**
llamado `indico`. Dos opciones:

- **Desde Git:** apuntá a este repo y, en "Compose Path", poné `docker-compose.dokploy.yml`.
  Cargá las variables del `.env` en la pestaña **Environment** del servicio.
- **Pegando el YAML:** copiá el contenido de `docker-compose.dokploy.yml` y las variables.

El dominio ya está definido por las **labels de Traefik** dentro del compose
(`indico.matudev.com.ar`, puerto interno `59999`, HTTPS con `letsencrypt`). No necesitás tocar
la pestaña Domains.

> **Importante — el dominio en las labels:** `docker-compose.dokploy.yml` tiene el host
> `indico.matudev.com.ar` escrito en las labels. Si cambiás de dominio, editá esas líneas
> (`Host(`...`)`). Con `matudev.com.ar` no hay que tocar nada.

**d) Deploy.** Dokploy levanta el stack. En el **primer arranque** la imagen inicializa el esquema
de la base de datos: seguí los logs hasta que el web escuche (ver §14).

**e) Bootstrap de Indico.** Cuando cargue por HTTPS, entrá una sola vez a:

```
https://indico.matudev.com.ar/bootstrap
```

Ahí creás el **usuario administrador** y los datos de la instancia (nombre, organización, zona
horaria). Esa página deja de estar disponible una vez que existe un admin.

---

## 12. Certificados HTTPS

**Con Dokploy/Traefik no corrés certbot ni tocás archivos de certificados.** Traefik, mediante
el cert resolver `letsencrypt`, **emite y renueva** los certificados automáticamente cuando:

1. El **DNS del dominio apunta a la VPS** (§4 verificado con `dig`).
2. El **puerto 80 está abierto** (Let's Encrypt valida por HTTP-01 contra `/.well-known/...`).
3. El servicio declara el `certresolver=letsencrypt` (por labels o por la pestaña Domains).

Al primer request al dominio, Traefik pide el certificado; puede tardar unos segundos la primera vez.

- **Renovación:** automática, Traefik la maneja. No hay timers que configurar.
- **Correo de Let's Encrypt / config global:** en **Settings** de Dokploy podés fijar el email de
  notificaciones de Let's Encrypt.
- **Redirect HTTP→HTTPS:** ya está en las labels (router `web` con `redirectscheme`). Cualquier
  visita por `http://` se manda a `https://`.

Si un certificado no se emite, casi siempre es DNS que todavía no propagó o el puerto 80 cerrado
(ver §18).

---

## 13. Variables del `.env`

El `.env` (copiado de `.env.example`) alimenta a `docker-compose.dokploy.yml`. **No se versiona**
(`.gitignore`). Guardá una copia segura aparte (gestor de secretos): perder `INDICO_SECRET_KEY`
o `PGPASSWORD` complica la recuperación.

| Variable | Qué es | Valor para este despliegue |
| -------- | ------ | -------------------------- |
| `INDICO_IMAGE` | Imagen/versión de Indico (fijar, no `latest`) | `ghcr.io/indico/indico:3.3` |
| `POSTGRES_IMAGE` | Imagen de Postgres | `postgres:15` |
| `REDIS_IMAGE` | Imagen de Redis | `redis:7` |
| `PGHOST` | Host de la DB (nombre del servicio) | `postgres` |
| `PGPORT` | Puerto de la DB | `5432` |
| `PGUSER` | Usuario de la DB | `indico` |
| `PGDATABASE` | Nombre de la DB | `indico` |
| `PGPASSWORD` | **Password de la DB** (secreto) | `openssl rand -base64 24` |
| `INDICO_SECRET_KEY` | **Clave de sesión/tokens** (secreto) | `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `INDICO_BASE_URL` | URL pública con HTTPS | `https://indico.matudev.com.ar` |
| `INDICO_USE_PROXY` | Indico detrás de proxy (Traefik) | `true` |
| `INDICO_DEFAULT_TIMEZONE` | Zona horaria | `America/Argentina/Buenos_Aires` |
| `INDICO_DEFAULT_LOCALE` | Idioma | `es_ES` |
| `INDICO_NO_REPLY_EMAIL` | Remitente no-reply | `noreply@matudev.com.ar` |
| `INDICO_SUPPORT_EMAIL` | Correo de soporte | `soporte@matudev.com.ar` |
| `INDICO_SMTP_HOST` | Servidor SMTP | el de tu proveedor |
| `INDICO_SMTP_PORT` | Puerto SMTP (submission) | `587` |
| `INDICO_SMTP_USE_TLS` | STARTTLS | `true` |
| `INDICO_SMTP_USE_SSL` | SSL directo | `false` |
| `INDICO_SMTP_LOGIN` | Usuario SMTP | según proveedor |
| `INDICO_SMTP_PASSWORD` | **Password SMTP** (secreto) | según proveedor |
| `INDICO_ENABLE_ROOMBOOKING` | Módulo de reservas de salas | `true` |

> Diferencia clave respecto al `.env.example` original: **ya no se usa `INDICO_HTTP_BIND`**
> (no se publican puertos; Traefik llega por la red interna al `59999`). Podés dejar la variable;
> el compose de Dokploy la ignora.

En Dokploy, estas variables se cargan en la pestaña **Environment** del servicio Compose
(o se leen del `.env` si desplegás desde Git con el `.env` presente en el server).

---

## 14. Logs

**Desde el panel de Dokploy:** cada servicio tiene una pestaña **Logs** en vivo (web, celery,
postgres, etc.). Es la vía normal para ver qué pasa.

**Desde la VPS (SSH), útil para diagnósticos:**

```bash
cd /opt/indico-selper
# Estado de los contenedores
docker compose -f docker-compose.dokploy.yml ps

# Logs del web de Indico (seguir en vivo)
docker compose -f docker-compose.dokploy.yml logs -f indico

# Logs de correo/tareas (Celery)
docker compose -f docker-compose.dokploy.yml logs -f indico-celery

# Logs de Traefik (enrutamiento / certificados) — gestionado por Dokploy:
docker logs -f dokploy-traefik    # el nombre exacto lo ves con: docker ps | grep traefik
```

- **Logs internos de Indico** (nivel app) van al volumen `indico-log` (`/opt/indico/log` dentro
  del contenedor), configurados por `data/logging.yaml`.
- **Rotación:** conviene limitar el tamaño de logs de Docker. Creá/editá `/etc/docker/daemon.json`:
  ```json
  {
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3" }
  }
  ```
  y `sudo systemctl restart docker` (afecta a contenedores nuevos).

---

## 15. Backups

Lo crítico a respaldar son **dos volúmenes**: la base de datos (`postgres-data`) y los archivos
subidos (`indico-archive`). También `indico-custom` si personalizás.

Este repo trae **`scripts/backup.sh`**, que hace dump de la DB + tar del storage. Está escrito
para `docker-compose.prod.yml`; para Dokploy, apuntalo al compose de Dokploy con la variable
`COMPOSE` o editá esa línea. Forma rápida sin editar el script:

```bash
cd /opt/indico-selper
chmod +x scripts/backup.sh
# Sobrescribir el compose que usa el script:
sed 's/docker-compose.prod.yml/docker-compose.dokploy.yml/' scripts/backup.sh > scripts/backup.dokploy.sh
chmod +x scripts/backup.dokploy.sh
./scripts/backup.dokploy.sh    # genera backups/db-*.sql.gz y archive-*.tar.gz
```

Programar diario con cron (03:30):

```bash
crontab -e
30 3 * * * cd /opt/indico-selper && ./scripts/backup.dokploy.sh >> backups/backup.log 2>&1
```

Comandos equivalentes manuales (por si preferís no usar el script):

```bash
# Dump de la base de datos
docker compose -f docker-compose.dokploy.yml exec -T postgres \
  pg_dump -U indico indico | gzip > backups/db-$(date +%F).sql.gz

# Archivos subidos
docker compose -f docker-compose.dokploy.yml exec -T indico \
  tar czf - -C /opt/indico archive > backups/archive-$(date +%F).tar.gz
```

> **Regla de oro:** llevá copias **fuera de la VPS** (otro server, almacenamiento de objetos como
> S3/Backblaze, o los snapshots del panel del proveedor). Un backup solo en la misma VPS no te
> salva si perdés el servidor. Dokploy también tiene backups programados de bases de datos en su
> panel; podés usarlos además del script.

Guardá **aparte y seguro** el `.env` (contiene `SECRET_KEY` y `PGPASSWORD`): sin esos valores,
un backup de la DB no alcanza para reconstruir el sitio idéntico.

---

## 16. Recuperación ante desastre y restauración completa

Escenario: la VPS se perdió (falla, borrado, migración). Reconstrucción completa en una VPS nueva:

1. **Aprovisionar VPS nueva** (§5) y **hardening** (§6).
2. **Repuntar el DNS** (§4): cambiar los registros A (`@`, `www`, `indico`, `dokploy`) a la
   **nueva IP**. Bajá el TTL a `300` con anticipación si sabés que vas a migrar.
3. **Instalar Docker + Dokploy** (§7, §8) y reasignar `dokploy.matudev.com.ar` al panel (§8.1).
4. **Traer el repo** y **restaurar el `.env`** desde tu copia segura (§13). Debe tener el
   **mismo `INDICO_SECRET_KEY` y `PGPASSWORD`** que la instalación original.
5. **Levantar el stack** en Dokploy con `docker-compose.dokploy.yml` (§11), **sin hacer bootstrap**
   (los datos vienen del backup).
6. **Restaurar la base de datos** (desde el backup más reciente):

   ```bash
   cd /opt/indico-selper
   gunzip -c backups/db-AAAA-MM-DD.sql.gz | \
     docker compose -f docker-compose.dokploy.yml exec -T postgres psql -U indico -d indico
   ```

7. **Restaurar los archivos subidos** (`indico-archive`):

   ```bash
   # Copiar el tar dentro del contenedor y extraerlo en /opt/indico
   docker compose -f docker-compose.dokploy.yml exec -T indico \
     tar xzf - -C /opt/indico < backups/archive-AAAA-MM-DD.tar.gz
   ```

8. **Reiniciar los servicios de Indico** para que tomen todo limpio:

   ```bash
   docker compose -f docker-compose.dokploy.yml up -d --force-recreate \
     indico indico-celery indico-celery-beat
   ```

9. **HTTPS:** Traefik vuelve a emitir los certificados solo, en cuanto el DNS apunte a la VPS
   nueva y el 80 esté abierto (§12). No hay que copiar certificados viejos.
10. **Verificar:** login, un evento existente, subida/descarga de un adjunto, y envío de un correo
    de prueba (§18).

> **Probá la restauración al menos una vez** en una VPS o entorno de prueba. Un backup que nunca
> se restauró no es un backup confiable.

---

## 17. Checklist previo a producción

**Dominio y DNS**
- [ ] `matudev.com.ar` registrado y a tu nombre.
- [ ] Registros A `@`, `www`, `indico`, `dokploy` → IP de la VPS (`dig` los cuatro resuelve OK).

**Servidor / hardening**
- [ ] Usuario sudo no-root; login SSH por clave; `PermitRootLogin no` y `PasswordAuthentication no`.
- [ ] `ufw` activo: solo 22, 80, 443. Panel 3000 cerrado o restringido a tu IP.
- [ ] `unattended-upgrades` y `fail2ban` instalados y activos.
- [ ] Snapshots del proveedor activados.

**Dokploy / Traefik**
- [ ] Dokploy instalado; admin del panel creado inmediatamente.
- [ ] Panel accesible por `https://dokploy.matudev.com.ar` (HTTPS + login); puerto 3000 cerrado en `ufw`.
- [ ] `dokploy-network` existe; Traefik levantado.

**Landing**
- [ ] `https://matudev.com.ar` y `https://www.matudev.com.ar` cargan por HTTPS.
- [ ] Redirect HTTP→HTTPS funcionando.

**Indico**
- [ ] `.env` completo: `INDICO_SECRET_KEY` y `PGPASSWORD` únicos (no los de ejemplo).
- [ ] `INDICO_BASE_URL=https://indico.matudev.com.ar` y `INDICO_USE_PROXY=true`.
- [ ] `INDICO_IMAGE` con versión fija (no `latest`).
- [ ] SMTP por puerto 587 + TLS, credenciales OK; SPF/DKIM/DMARC en el DNS.
- [ ] Bootstrap hecho (admin creado); `/bootstrap` ya no accesible.
- [ ] Postgres/Redis **no** exponen puertos; solo en `indico-internal`.

**HTTPS / backups**
- [ ] Certificados emitidos por Traefik para los tres dominios; renovación automática confiable.
- [ ] Backups automáticos (cron) + copia **fuera de la VPS**; restauración probada.
- [ ] `.env` respaldado en lugar seguro y aparte.

**Logs**
- [ ] Rotación de logs de Docker configurada (`daemon.json`).
- [ ] Sabés ver logs de web, celery y Traefik.

---

## 18. Troubleshooting

**El dominio no carga / "Bad Gateway" o "404" de Traefik**
- ¿El contenedor está `healthy`? `docker compose -f docker-compose.dokploy.yml ps`.
- ¿El servicio está en `dokploy-network`? (el web de Indico y la landing deben estarlo).
- Revisá las labels: `Host(...)` correcto y `loadbalancer.server.port` = puerto interno real
  (`59999` para Indico, `80` para la landing).
- Logs de Traefik: `docker logs dokploy-traefik | tail -50`.

**No se emite el certificado HTTPS**
- `dig +short indico.matudev.com.ar` debe devolver la IP de la VPS (DNS propagado).
- El **puerto 80** debe estar abierto (Let's Encrypt valida por HTTP). Revisá `ufw` y el firewall
  del panel del proveedor.
- Si usás Cloudflare con proxy (nube naranja), poné el registro en **"DNS only"** hasta que
  emita el cert, o configurá el modo SSL "Full".
- No repitas intentos en loop: Let's Encrypt tiene **rate limits**. Corregí la causa y reintentá.

**Enlaces a `http://` o "mixed content" en Indico**
- Verificá `INDICO_BASE_URL=https://...` y `INDICO_USE_PROXY=true`. Recreá los contenedores tras
  cambiar `.env`.

**No se envían correos**
- `docker compose -f docker-compose.dokploy.yml logs -f indico-celery`.
- Confirmá puerto **587** (no 25), TLS y credenciales en `.env`. Recordá que el 25 saliente suele
  estar bloqueado por el proveedor.

**Subidas grandes fallan (413 / body too large)**
- El límite lo pone Traefik. En las labels de Indico está `buffering.maxRequestBodyBytes` en 1 GB;
  subilo si necesitás más y redeployá.

**El panel 3000 quedó expuesto**
- Cerralo en `ufw` y accedé por túnel SSH o asignale un subdominio con HTTPS + login en Dokploy.

**Falta de memoria / contenedores reiniciando**
- `docker stats`. Indico + Postgres + Redis + Celery + Dokploy pesan: ampliá RAM o reducí workers.
