# Servidor casero: convertir una PC con Windows en un "VPS" con Ubuntu + Dokploy

Guía paso a paso para reutilizar una **PC de tu casa** (hoy con Windows) como servidor tipo VPS:
instalar **Ubuntu Server**, dejarlo endurecido, instalar **Docker + Dokploy**, **exponerlo a
Internet** desde una conexión hogareña (con IP dinámica, CGNAT o puertos bloqueados) y levantar
una **landing de prueba** para confirmar que quedó bien.

Complementa a [`DEPLOY-DOKPLOY.md`](DEPLOY-DOKPLOY.md): para todo lo que es Dokploy/Traefik,
landing e Indico, esa guía es la referencia; acá cubrimos lo específico de **montar el servidor en
casa y publicarlo**. Cuando algo ya está explicado allá, lo enlazo en vez de repetirlo.

> ⚠️ **Aviso importante:** instalar Ubuntu borrando Windows es **destructivo**. Vas a perder todo
> lo que haya en el disco elegido. **Respaldá tus datos antes** (§4). Leé el §3 para decidir el
> método (borrar Windows, dual boot o VM) según lo que necesites.

---

## Índice

1. [Esquema de arquitectura](#1-esquema-de-arquitectura)
2. [Requisitos y evaluación del hardware](#2-requisitos-y-evaluación-del-hardware)
3. [Elegir el método de instalación](#3-elegir-el-método-de-instalación)
4. [Respaldar Windows](#4-respaldar-windows)
5. [Crear el USB booteable de Ubuntu](#5-crear-el-usb-booteable-de-ubuntu)
6. [Preparar la BIOS/UEFI](#6-preparar-la-biosuefi)
7. [Instalar Ubuntu Server 24.04 LTS](#7-instalar-ubuntu-server-2404-lts)
8. [Post-instalación: red local fija y hardening](#8-post-instalación-red-local-fija-y-hardening)
9. [Instalar Docker + Dokploy](#9-instalar-docker--dokploy)
10. [Diagnóstico de tu conexión hogareña](#10-diagnóstico-de-tu-conexión-hogareña)
11. [Exponer el servidor a Internet](#11-exponer-el-servidor-a-internet)
    - [A. Cloudflare Tunnel (recomendada)](#11a-cloudflare-tunnel-recomendada)
    - [B. Port forwarding + DNS dinámico](#11b-port-forwarding--dns-dinámico)
    - [C. Tailscale (acceso privado de administración)](#11c-tailscale-acceso-privado-de-administración)
12. [Levantar una landing de prueba](#12-levantar-una-landing-de-prueba)
13. [Operación de un server hogareño](#13-operación-de-un-server-hogareño)
14. [Checklist](#14-checklist)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Esquema de arquitectura

El problema del hogar: la mayoría de las conexiones **no tienen IP pública fija** y muchas están
detrás de **CGNAT** o con los **puertos 80/443 bloqueados** por el ISP. La solución principal es un
**Cloudflare Tunnel**: un cliente (`cloudflared`) en tu PC abre una conexión **saliente** a
Cloudflare; el tráfico público entra por Cloudflare y baja por ese túnel. **No abrís puertos en el
router y ni siquiera necesitás IP pública.**

```
                         Internet
                            │
                 matudev.com.ar (DNS en Cloudflare)
                            │  HTTPS (cert en el borde de Cloudflare)
                            ▼
                   ┌──────────────────┐
                   │    Cloudflare     │
                   └────────┬─────────┘
                            │  túnel saliente (cloudflared)
        ── Router hogareño ─┼──────────────────────────────── (sin port-forward)
                            ▼
      ┌───────────────────────────────────────────────────────┐
      │            PC casera  (Ubuntu Server + Docker)          │
      │                                                         │
      │   cloudflared ──► Traefik (:80) ──► landing / indico    │
      │                     (Dokploy administra Traefik)        │
      │                                                         │
      │   Tailscale (opcional) ──► panel Dokploy (admin privado)│
      └───────────────────────────────────────────────────────┘
```

Alternativa (§11B): si tu conexión **sí** tiene IP pública y el ISP **no** bloquea 80/443, podés
usar **port forwarding + DNS dinámico** en vez del túnel. En ese caso Traefik emite los
certificados con Let's Encrypt igual que en `DEPLOY-DOKPLOY.md`.

---

## 2. Requisitos y evaluación del hardware

**Mínimos de la PC (para Dokploy + una landing / apps chicas):**

| Recurso | Mínimo | Cómodo |
| ------- | ------ | ------ |
| CPU     | 2 núcleos x86-64 | 4 núcleos |
| RAM     | 4 GB   | 8–16 GB |
| Disco   | SSD 40 GB | SSD 120 GB+ |
| Red     | Cable Ethernet al router (no WiFi) | Ethernet |

- **x86-64:** cualquier PC/notebook de escritorio de los últimos ~12 años sirve. (Indico completo
  pide más RAM; para "landing + probar Dokploy" con 4 GB alcanza.)
- **Ethernet, no WiFi:** un server debe estar cableado al router. Más estable y sin cortes.
- **Energía:** va a estar **encendida 24/7**. Considerá consumo eléctrico y, si podés, una **UPS**
  (batería) para que un microcorte no la apague.
- **Notebook como server:** sirve muy bien (bajo consumo), pero configurá que **no se suspenda al
  cerrar la tapa** (§8) y, idealmente, dejá la batería como mini-UPS.

**Anotá antes de empezar:**
- Marca/modelo de la PC (para buscar la tecla de la BIOS).
- Si tiene **uno o varios discos** (importante para decidir borrar vs. dual boot, §3).

---

## 3. Elegir el método de instalación

Cuatro caminos posibles. Recomendación: **Opción 1 (dedicar la PC a Ubuntu)** si esa máquina va a
ser el server; es lo más simple y estable.

| Opción | Qué es | Ventaja | Desventaja | Cuándo |
| ------ | ------ | ------- | ---------- | ------ |
| **1. Ubuntu solo (borrar Windows)** | Formatea el disco e instala Ubuntu Server | Simple, estable, todo el recurso para el server | Perdés Windows en esa PC | La PC se dedica a server |
| **2. Dual boot** | Ubuntu y Windows conviven; elegís al arrancar | Conservás Windows | El server no está "siempre" (si arranca Windows, no hay server); más frágil | Querés seguir usando Windows a veces |
| **3. VM (Hyper-V/VirtualBox)** | Ubuntu como máquina virtual dentro de Windows | No tocás el disco de Windows | Overhead, depende de que Windows esté prendido, red más enredada | Solo para probar |
| **4. WSL2** | Ubuntu dentro de Windows | Rápido de instalar | **No recomendado para Dokploy** (Swarm/servicios/arranque automático dan problemas) | No usar para esto |

> Para un server real y "siempre encendido", **Opción 1**. Si dudás y querés conservar Windows,
> **Opción 2 (dual boot)**, sabiendo que el server solo está disponible cuando la PC arrancó en
> Ubuntu. El resto de la guía asume **Opción 1** (indico las diferencias del dual boot donde
> aplican).

**Ubuntu Server vs. Ubuntu Desktop:** usá **Ubuntu Server** (sin escritorio gráfico): consume
menos y es lo esperable en un server. Si te resulta más cómodo tener entorno gráfico al principio,
podés instalar **Ubuntu Desktop**, pero no es necesario: todo se hace por terminal/SSH.

**Versión:** **Ubuntu Server 24.04 LTS** (soporte largo hasta 2029). Alternativa: 22.04 LTS.

---

## 4. Respaldar Windows

**Antes de tocar nada**, si en esa PC hay algo que te importa:

1. Copiá tus archivos (Documentos, Descargas, Escritorio, fotos, proyectos) a un **disco externo**
   o a la nube (OneDrive/Google Drive).
2. Exportá lo que no sea archivo suelto: contraseñas del navegador, licencias, claves.
3. Si querés poder **volver a Windows**, creá un **medio de instalación de Windows** con la
   [Media Creation Tool](https://www.microsoft.com/software-download) en otro USB, y anotá tu clave
   de licencia (`Win`, normalmente ligada a la cuenta Microsoft o a la placa).
4. Verificá que el respaldo **abre y está completo** en el otro dispositivo antes de continuar.

> Si vas por **dual boot** (Opción 2), igual respaldá: redimensionar particiones tiene riesgo.

---

## 5. Crear el USB booteable de Ubuntu

Necesitás **otra computadora con internet** y un **pendrive de 8 GB o más** (se borra entero).

1. Descargá la ISO de **Ubuntu Server 24.04 LTS** desde https://ubuntu.com/download/server
   (archivo `.iso`, ~2–3 GB).
2. Descargá **Rufus** (https://rufus.ie) en Windows, o **balenaEtcher** (multiplataforma).
3. Insertá el pendrive. En **Rufus**:
   - **Dispositivo:** tu pendrive.
   - **Elección de arranque:** la ISO de Ubuntu (botón SELECCIONAR).
   - **Esquema de partición:** **GPT** (para UEFI moderno). Si la PC es muy vieja y solo BIOS
     legacy, usá **MBR**.
   - **Sistema destino:** **UEFI** (o BIOS legacy si corresponde).
   - **EMPEZAR** → si pregunta modo ISO/DD, elegí **modo Imagen ISO**. Confirmá el borrado.
4. Al terminar, expulsá el pendrive con seguridad.

---

## 6. Preparar la BIOS/UEFI

En la **PC que será server**:

1. **Desactivar "Inicio rápido" de Windows** antes de apagar (si aún está Windows y vas a dual
   boot o querés evitar que el disco quede "bloqueado"):
   Panel de control → Opciones de energía → "Elegir el comportamiento de los botones" →
   "Cambiar la configuración actualmente no disponible" → **destildar "Activar inicio rápido"**.
2. Apagá la PC. Encendela y entrá a la **BIOS/UEFI** pulsando la tecla del fabricante al arrancar
   (suele ser **Supr/Del**, **F2**, **F10**, **F12** o **Esc**; buscá el modelo si no sabés).
3. Ajustá:
   - **Secure Boot:** Ubuntu moderno lo soporta, pero si la instalación falla, **desactivalo**.
   - **Boot Mode:** **UEFI** (recomendado). Coincidir con cómo hiciste el USB (§5).
   - **Orden de arranque (Boot Order):** poné el **USB primero** (solo para instalar; luego se
     revierte).
   - **Restore on AC Power Loss / After Power Failure → "Power On"** (si existe): hace que la PC
     **se vuelva a encender sola tras un corte de luz**. Clave para un server 24/7.
4. Guardá y salí (normalmente **F10**). Con el USB puesto, debería bootear el instalador de Ubuntu.

> **Portátil:** además, más adelante configurás que **no se suspenda con la tapa cerrada** (§8).

---

## 7. Instalar Ubuntu Server 24.04 LTS

Arranca el instalador (modo texto, se navega con teclado). Pasos:

1. **Idioma** del instalador: English (o Español).
2. **Actualizar el instalador** si lo ofrece: sí.
3. **Teclado (Keyboard):** elegí **Spanish (Latin American)** si tu teclado es latino.
4. **Tipo de instalación:** **Ubuntu Server** (no la "minimized").
5. **Red (Network):** con el cable Ethernet conectado, debería tomar IP por DHCP automáticamente.
   Dejalo así por ahora (la IP fija la ponemos después, §8). Anotá la IP que muestra.
6. **Proxy:** vacío.
7. **Mirror:** el que sugiere.
8. **Almacenamiento (Storage):**
   - **Opción 1 (borrar todo):** elegí **"Use an entire disk"** sobre el disco de la PC. Opcional:
     activar LVM (deja default). Confirmá el borrado (**esto elimina Windows**).
   - **Opción 2 (dual boot):** más complejo; requiere haber dejado espacio libre desde Windows y
     particionar a mano. Si vas por acá y no tenés experiencia, hacelo con cuidado o considerá la
     Opción 1.
9. **Confirmar** el resumen de particiones → **Done** → confirmar que se va a formatear.
10. **Perfil (Profile):** creá tu usuario. Ejemplo:
    - Your name: `Matias`
    - Server name (hostname): `matudev-server`
    - Username: `matias`
    - Password: una fuerte (la vas a usar para `sudo`).
11. **Upgrade to Ubuntu Pro:** **Skip** (no hace falta).
12. **SSH:** **marcá "Install OpenSSH server"** (importante, para administrar por red). Si tenés tu
    clave pública en GitHub, podés importarla; si no, después la cargás (§8).
13. **Featured server snaps:** no marques nada (Docker lo instalamos aparte, §9).
14. Esperá la instalación. Al terminar → **Reboot Now**. **Quitá el USB** cuando lo pida.
15. Volvé a la BIOS solo si no arranca del disco; normalmente ya bootea Ubuntu.

Al reiniciar, entrá con tu usuario y contraseña en la consola. Anotá la **IP local** (la vas a
necesitar para SSH):

```bash
ip a          # buscá la IP del tipo 192.168.x.x en la interfaz Ethernet (eth0/enp*)
```

Desde otra PC de tu red probá el acceso remoto por SSH:

```bash
ssh matias@192.168.x.x
```

A partir de acá administrás todo por SSH; no hace falta teclado/monitor en el server (podés
dejarlo "headless").

---

## 8. Post-instalación: red local fija y hardening

**a) IP local fija (para que el router siempre la encuentre).** Dos formas; elegí una:

- **Recomendada — reserva DHCP en el router:** entrá al panel del router (§10), buscá
  "DHCP reservation" / "IP estática por MAC" y **fijá la IP** de la MAC del server (p. ej.
  `192.168.1.50`). Simple y no toca el server.
- **Alternativa — IP estática en Ubuntu (Netplan):** editá `/etc/netplan/*.yaml`:
  ```yaml
  network:
    version: 2
    ethernets:
      enp3s0:                      # tu interfaz real (ver con: ip a)
        dhcp4: no
        addresses: [192.168.1.50/24]
        routes:
          - to: default
            via: 192.168.1.1       # IP del router
        nameservers:
          addresses: [1.1.1.1, 8.8.8.8]
  ```
  Aplicar: `sudo netplan apply`.

**b) Actualizar el sistema:**

```bash
sudo apt update && sudo apt upgrade -y
```

**c) Hardening** (igual criterio que `DEPLOY-DOKPLOY.md` §6, resumido):

```bash
# Si NO importaste tu clave SSH en la instalacion, cargala ahora desde tu PC:
#   ssh-copy-id matias@192.168.1.50
# Luego endurecé SSH:
sudo nano /etc/ssh/sshd_config     # PasswordAuthentication no ; PermitRootLogin no
sudo systemctl restart ssh

# Firewall local
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
# Con Cloudflare Tunnel (§11A) NO hace falta abrir 80/443 en ufw ni en el router.
# Si vas por port-forwarding (§11B), ahí sí: sudo ufw allow 80,443/tcp
sudo ufw enable

# Fail2ban + actualizaciones automaticas de seguridad
sudo apt install -y fail2ban unattended-upgrades
sudo systemctl enable --now fail2ban
sudo dpkg-reconfigure -plow unattended-upgrades

# Zona horaria
sudo timedatectl set-timezone America/Argentina/Buenos_Aires
```

**d) Que NO se suspenda (clave en notebooks y para 24/7):**

```bash
# Evitar suspensión/hibernación del sistema
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

En **notebooks**, además, ignorá el cierre de tapa: editá `/etc/systemd/logind.conf` y poné
`HandleLidSwitch=ignore` (y `HandleLidSwitchExternalPower=ignore`), luego
`sudo systemctl restart systemd-logind`.

---

## 9. Instalar Docker + Dokploy

Igual que en [`DEPLOY-DOKPLOY.md`](DEPLOY-DOKPLOY.md) §7–§8. Resumen:

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER      # re-logueá la sesión SSH

# Dokploy (instala lo que falte, inicializa Swarm, crea dokploy-network,
# levanta Traefik en 80/443 y el panel en el puerto 3000)
curl -sSL https://dokploy.com/install.sh | sudo sh
```

**Acceder al panel de Dokploy** (aún dentro de tu red local, sin exponerlo a Internet todavía):
desde tu PC en la misma red, abrí `http://192.168.1.50:3000` y **creá el usuario admin cuanto
antes**. Más adelante lo dejás accesible de forma privada por Tailscale (§11C) o por un subdominio.

> **No abras el 3000 al router/Internet.** El panel es la parte más sensible.

---

## 10. Diagnóstico de tu conexión hogareña

Antes de exponer nada, entendé qué te da tu ISP. Esto define **qué método del §11 usar**.

**a) ¿Tenés IP pública o estás detrás de CGNAT?**
Comparás la IP que ve tu router (WAN) contra la que ve Internet:

```bash
# IP publica segun Internet:
curl -s https://ifconfig.me ; echo
```

Ahora mirá la **IP WAN del router** en su panel de administración (ver punto c). Si:
- **Coinciden** → tenés IP pública "directa" (podría servir port-forwarding).
- **Son distintas** (o la WAN es del rango `100.64.x.x`–`100.127.x.x`) → estás detrás de **CGNAT**.
  El port-forwarding **no funciona**. → Usá **Cloudflare Tunnel (§11A)**.

**b) ¿El ISP bloquea los puertos 80/443 entrantes?**
Muchos ISP residenciales (varios en Argentina) bloquean el 80 y 443 entrantes. Si es tu caso, el
port-forwarding tampoco sirve para web → **Cloudflare Tunnel**. (Con el túnel esto no importa,
porque la conexión es saliente.)

**c) Entrar al panel del router** (para reserva DHCP y, si aplica, port-forwarding):
Abrí en el navegador la IP del router (típicamente `192.168.1.1` o `192.168.0.1`; verla con
`ip r | grep default`). Usuario/clave suele estar en una etiqueta del equipo.

> **Conclusión práctica:** si no estás 100% seguro de tener IP pública **y** puertos 80/443 libres,
> andá directo por **Cloudflare Tunnel (§11A)**. Es lo que funciona en la mayoría de los hogares,
> es gratis, **no expone tu IP** y no requiere tocar el router.

---

## 11. Exponer el servidor a Internet

### 11A. Cloudflare Tunnel (recomendada)

`cloudflared` corre en el server y abre un túnel saliente a Cloudflare. El público entra por
Cloudflare (que además pone el **HTTPS** en el borde) y baja por el túnel hasta **Traefik** en tu
PC. **No abrís puertos ni necesitás IP pública.**

**Requisito:** tu dominio (`matudev.com.ar`) con el **DNS administrado por Cloudflare**
(nameservers de Cloudflare cargados en NIC.ar; ver `DEPLOY-DOKPLOY.md` §3, opción Cloudflare).

**Paso a paso (modo panel, el más simple):**

1. En el **dashboard de Cloudflare** → **Zero Trust** → **Networks → Tunnels** → **Create a tunnel**.
2. Tipo **Cloudflared** → nombre `matudev-home` → **Save**.
3. Cloudflare muestra un **comando de instalación con un token**. En el server, instalá cloudflared
   y pegá ese comando (algo así):
   ```bash
   # Instalar cloudflared (Debian/Ubuntu)
   curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
   sudo dpkg -i cloudflared.deb

   # Ejecutar el conector como servicio (el TOKEN te lo da el panel):
   sudo cloudflared service install eyJh...TOKEN...
   ```
   El túnel debería aparecer **HEALTHY/Connected** en el panel.
4. En **Public Hostnames** del túnel, agregá una entrada por cada dominio, apuntando a **Traefik**
   (que escucha en el 80 dentro del server):

   | Subdomain | Domain          | Service (Type / URL)        |
   | --------- | --------------- | --------------------------- |
   | (vacío)   | `matudev.com.ar`| `HTTP` → `http://localhost:80` |
   | `www`     | `matudev.com.ar`| `HTTP` → `http://localhost:80` |
   | `indico`  | `matudev.com.ar`| `HTTP` → `http://localhost:80` |

   Cloudflare crea **solo** los registros DNS (tipo CNAME "proxied") de esos hostnames apuntando al
   túnel. No cargás IPs a mano.
5. **SSL/TLS:** en Cloudflare, en **SSL/TLS → Overview**, poné el modo en **Full**. Cloudflare
   pone el certificado público; el origen (Traefik) recibe HTTP por el túnel.

**Ajuste en Traefik/labels (importante):** como **Cloudflare ya hace el HTTPS**, en este escenario
los servicios deben enrutarse por el entrypoint **`web` (HTTP)** y **sin** redirect a HTTPS ni
Let's Encrypt (Traefik no puede validar LE porque el 80 no es público). Es decir: para la landing e
Indico usá labels solo de `web` (ver el compose simplificado en §12), o en la pestaña **Domains**
de Dokploy agregá el dominio **sin** activar HTTPS/Let's Encrypt.

> **Acceso admin (panel Dokploy) por el túnel, protegido:** podés agregar un Public Hostname
> `dokploy.matudev.com.ar` → `http://localhost:3000` y, en **Zero Trust → Access → Applications**,
> protegerlo con login (email OTP/Google). Así el panel queda accesible pero **solo para vos**.
> Alternativa sin exponerlo: administralo por Tailscale (§11C).

### 11B. Port forwarding + DNS dinámico

Solo si el §10 confirmó que tenés **IP pública directa (sin CGNAT)** y el ISP **no bloquea 80/443**.

1. **Reserva DHCP** para el server (§8a), p. ej. `192.168.1.50`.
2. En el router, **Port Forwarding**: redirigí **80→192.168.1.50:80** y **443→192.168.1.50:443**.
3. **Firewall del server:** `sudo ufw allow 80,443/tcp`.
4. **IP dinámica → DNS dinámico:** como la IP pública hogareña **cambia**, necesitás un cliente DDNS
   que actualice el DNS cuando cambie. Opciones:
   - **Cloudflare DDNS:** un script/cron o `ddclient` que actualiza el registro A vía API de
     Cloudflare cuando cambia tu IP.
   - **DuckDNS / No-IP:** subdominios gratuitos que apuntás por CNAME.
5. Con el DNS resolviendo a tu IP y los puertos abiertos, **Traefik emite los certificados con
   Let's Encrypt** igual que en `DEPLOY-DOKPLOY.md` (labels con `websecure` + `certresolver`).

> Este camino expone tu **IP hogareña** y depende de que el ISP colabore. Si podés, preferí el
> túnel (§11A): es más simple y más seguro.

### 11C. Tailscale (acceso privado de administración)

Para administrar el server (SSH, panel Dokploy) **sin exponerlo**, instalá **Tailscale**: crea una
red privada (VPN mesh) entre tus dispositivos.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Seguí el link para loguearte. Después accedés al server por su **IP de Tailscale** (100.x.y.z)
desde tu notebook/celular con Tailscale instalado, estés donde estés:

```bash
ssh matias@100.x.y.z
# Panel Dokploy privado:  http://100.x.y.z:3000
```

Es la forma más cómoda y segura de entrar al panel: no publicás el 3000 en ningún lado.

---

## 12. Levantar una landing de prueba

Objetivo: confirmar que todo el camino (Cloudflare → túnel → Traefik → contenedor) funciona.

**a)** En Dokploy creá un **Project** y dentro un servicio **Compose** llamado `landing`, con este
YAML **adaptado a Cloudflare Tunnel** (HTTP por el entrypoint `web`, sin Let's Encrypt: el HTTPS lo
pone Cloudflare):

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
      - "traefik.http.routers.landing.rule=Host(`matudev.com.ar`) || Host(`www.matudev.com.ar`)"
      - "traefik.http.routers.landing.entrypoints=web"
      - "traefik.http.services.landing.loadbalancer.server.port=80"

networks:
  dokploy-network:
    external: true
```

Y un `site/index.html` de prueba:

```html
<!doctype html>
<html lang="es">
  <head><meta charset="utf-8" /><title>Matudev — server casero</title></head>
  <body>
    <h1>¡Funciona! 🎉</h1>
    <p>Landing servida desde mi PC en casa, vía Cloudflare Tunnel + Dokploy.</p>
  </body>
</html>
```

> Si en cambio vas por **port-forwarding (§11B)** con Let's Encrypt, usá el compose de la landing de
> `DEPLOY-DOKPLOY.md` §10 (con `websecure` + `certresolver=letsencrypt`), no este.

**b) Deploy** en Dokploy.

**c) Verificar** desde afuera de tu casa (idealmente con datos móviles, para no depender de la red
local):

```bash
# Que el DNS resuelva a Cloudflare (IPs de Cloudflare, no tu IP hogareña):
dig +short matudev.com.ar

# Que responda por HTTPS:
curl -I https://matudev.com.ar
```

En el navegador, `https://matudev.com.ar` debe mostrar el "¡Funciona!" con **candado válido**
(certificado de Cloudflare). Si lo ves, el server casero quedó publicado correctamente. 🎉

Para el stack de **Indico** en este mismo server, seguí `DEPLOY-DOKPLOY.md` §11, recordando que con
Cloudflare Tunnel las labels van por el entrypoint `web` (sin Let's Encrypt), igual que la landing.

---

## 13. Operación de un server hogareño

- **Encendido 24/7 y cortes de luz:** configurá "Power On after AC loss" en la BIOS (§6) y, si
  podés, una **UPS**. Sin eso, un corte deja el sitio caído hasta que vuelvas a encender la PC.
- **IP dinámica:** con Cloudflare Tunnel **no te afecta** (la conexión es saliente). Con
  port-forwarding, dependés del cliente DDNS (§11B).
- **Arranque automático de los servicios:** Docker y los contenedores tienen `restart:
  unless-stopped`, y `cloudflared`/Dokploy corren como servicios: tras un reinicio, todo vuelve
  solo. Verificalo reiniciando una vez a propósito: `sudo reboot`.
- **Backups:** el disco de una PC casera puede fallar. Aplicá los backups de `DEPLOY-DOKPLOY.md`
  §15 y **sacá copias fuera de la PC** (otro disco, nube). Un server casero **no** reemplaza tener
  respaldo externo.
- **Actualizaciones:** `sudo apt update && sudo apt upgrade -y` cada tanto; los contenedores se
  actualizan desde Dokploy.
- **Temperatura/ruido/ubicación:** ponela ventilada, sin tapar rejillas, lejos de humedad.
- **Límites vs. una VPS:** dependés de tu luz e internet hogareños. Es ideal para **empezar sin
  pagar** y para servicios personales o de bajo tráfico; si el proyecto crece o necesita alta
  disponibilidad, migrás a una VPS (misma guía `DEPLOY-DOKPLOY.md`, solo cambia dónde corre).

---

## 14. Checklist

**Instalación**
- [ ] Datos de Windows respaldados y verificados (§4).
- [ ] USB de Ubuntu Server 24.04 creado (§5).
- [ ] BIOS: boot USB, UEFI, y **"Power On after AC loss"** activado (§6).
- [ ] Ubuntu instalado; **OpenSSH server** activo; acceso por SSH desde otra PC OK (§7).

**Servidor**
- [ ] IP local fija (reserva DHCP o Netplan) (§8a).
- [ ] Sistema actualizado; SSH por clave; `ufw`, `fail2ban`, `unattended-upgrades` activos (§8c).
- [ ] Suspensión desactivada; en notebook, tapa ignorada (§8d).
- [ ] Docker + Dokploy instalados; admin del panel creado (§9).

**Red / exposición**
- [ ] Diagnóstico hecho: sabés si hay CGNAT y si 80/443 están bloqueados (§10).
- [ ] Método elegido: **Cloudflare Tunnel** (§11A) o port-forwarding+DDNS (§11B).
- [ ] Túnel `HEALTHY`; Public Hostnames apuntando a `http://localhost:80`; SSL/TLS en **Full** (§11A).
- [ ] Panel Dokploy accesible de forma **privada** (Tailscale §11C o Access), 3000 no expuesto.

**Verificación**
- [ ] `dig` del dominio resuelve a Cloudflare; `https://matudev.com.ar` carga con candado válido.
- [ ] Probado **desde fuera de la red local** (datos móviles).
- [ ] Reinicio de prueba (`sudo reboot`): todo vuelve solo.
- [ ] Backups configurados y con copia fuera de la PC.

---

## 15. Troubleshooting

**No bootea del USB**
- Revisá orden de arranque y modo (UEFI vs legacy) en la BIOS (§6). Desactivá Secure Boot si falla.
- Recreá el USB (a veces la grabación queda mal); probá otro puerto USB.

**Instalé Ubuntu pero no tengo internet cableado**
- `ip a` para ver la interfaz; confirmá el cable al router. `ip r` debe mostrar un `default via`.
  Revisá Netplan (§8a) si pusiste IP estática mal.

**No entro por SSH**
- ¿Instalaste OpenSSH server (§7, paso 12)? Verificá: `sudo systemctl status ssh`.
- ¿IP correcta? (`ip a`). ¿`ufw` permite OpenSSH? (`sudo ufw status`).

**El túnel de Cloudflare no conecta (no queda HEALTHY)**
- `sudo systemctl status cloudflared` y `sudo journalctl -u cloudflared -f`.
- El server necesita **salida a Internet** (el túnel es saliente). No requiere puertos abiertos.
- Reinstalá el conector con el token correcto del panel.

**El dominio no carga / error 502/1033 de Cloudflare**
- El túnel debe estar HEALTHY y el **Public Hostname** apuntar a `http://localhost:80` (Traefik).
- Traefik debe estar arriba: `docker ps | grep traefik`. La landing en `dokploy-network` y con las
  labels del entrypoint `web` (§12).
- Verificá que el servicio no tenga `redirect a https`/`certresolver` (eso es solo para §11B).

**Redirect infinito / "too many redirects"**
- Pasa si Cloudflare está en modo "Flexible" y además Traefik redirige a HTTPS. Solución: Cloudflare
  en **Full** (§11A, paso 5) y **sin** redirect a HTTPS en las labels (entrypoint `web` solamente).

**Puerto 80/443 no llega (port-forwarding §11B)**
- Casi seguro **CGNAT** o **ISP bloqueando** esos puertos (§10). Solución real: pasar a Cloudflare
  Tunnel (§11A).

**Se apagó y no volvió tras un corte de luz**
- Activá "Restore on AC Power Loss → Power On" en la BIOS (§6). Considerá una UPS.

**El server anda pero se suspende solo**
- Aplicá el `systemctl mask ...sleep...` y, en notebook, `HandleLidSwitch=ignore` (§8d).
