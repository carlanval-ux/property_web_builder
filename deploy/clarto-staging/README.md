# CLARTO Inmobiliaria — staging

Entorno de staging con **Liberu Real Estate** como backoffice y fuente principal
de inmuebles y **PropertyWebBuilder (PWB)** como catálogo público. Todo va en
Docker Compose sobre un único VPS, con HTTPS automático y despliegue
reproducible desde esta rama (`staging/clarto` del fork de PWB).

```
                 Internet (80/443)
                        │
                     Caddy  ── TLS Let's Encrypt, cabeceras noindex, basic auth en paneles
             ┌──────────┴───────────┐
   crm.<host>  (todo con basic auth   catalogo.<host>  (público; paneles con basic auth)
   salvo /api/* y /up)
             │                        │
        liberu-app (Apache+PHP 8.5)  pwb-web (Puma, Rails 8.1)
        liberu-worker / scheduler    pwb-worker (Solid Queue)
             │                        │
        liberu-db (MySQL 8.4)        pwb-db (PostgreSQL 17)
        vol. liberu_storage ──ro──▶  pwb-sync ── cada 5 min: rake pwb:liberu:sync
                                     vol. pwb_storage (fotos del catálogo)
```

## Versiones fijadas

| Pieza | Versión |
|---|---|
| Liberu | fork `carlanval-ux/realstate` @ `1d0045b8` (`versions.env`) |
| PWB | fork `carlanval-ux/property_web_builder`, rama `staging/clarto` (commit desplegado en `state/last-deploy.txt`) |
| PHP / Apache (Liberu) | `php:8.5-apache-trixie`, Composer 2.8 |
| Ruby / Node (PWB) | `ruby:3.4.7-slim-bookworm`, `node:22.18-bookworm-slim` |
| Bases de datos | `mysql:8.4.6`, `postgres:17.6-alpine` |
| Proxy | `caddy:2.10.2-alpine` |

Ambas aplicaciones se construyen con Dockerfiles propios de staging
(`liberu/Dockerfile`, `pwb/Dockerfile`), porque las imágenes oficiales no
arrancan tal cual: la de Liberu usa Octane/RoadRunner sin el binario `rr` y la
de PWB falla en `bootsnap precompile` (la gema no está en el Gemfile).

## Despliegue

Primera vez, en un Ubuntu limpio (usuario con sudo):

```bash
sudo mkdir -p /srv/clarto-staging && sudo chown "$USER" /srv/clarto-staging
git clone -b staging/clarto https://github.com/carlanval-ux/property_web_builder.git /srv/clarto-staging/pwb
cd /srv/clarto-staging/pwb/deploy/clarto-staging
sudo scripts/install-host.sh "$USER"      # Docker (si falta), ufw 22/80/443, logs, timer de backup
newgrp docker
scripts/init-env.sh                        # genera .env y secrets/ (nunca se versionan)
scripts/deploy.sh                          # build + migraciones + bootstrap + arranque + 1.ª sincronización
```

Actualizaciones: `git pull && scripts/deploy.sh`. Para cambiar la versión de
Liberu se edita `LIBERU_REF` en `versions.env`.

`init-env.sh` usa por defecto nombres `crm.<ip>.sslip.io` y
`catalogo.<ip>.sslip.io`. Para dominios propios:
`scripts/init-env.sh --liberu-host crm.staging.clarto.es --pwb-host staging.clarto.es`
(o se editan `LIBERU_HOST`/`PWB_HOST` en `.env`) y después `scripts/deploy.sh`.

Credenciales generadas: `secrets/credentials.txt` (modo 600, solo en el servidor).

## Acceso restringido

* **Liberu**: todo el host pide *basic auth* (además del login de Filament),
  incluidas las fotos de `/storage`. Quedan abiertos solo `/api/*`
  (Sanctum; el listado público ya solo devuelve inmuebles publicados) y `/up`.
* **PWB**: el catálogo es público; `site_admin`, `tenant_admin`, editor,
  login, `api_manage`, `/api/v1`, importación/exportación, dashboards
  (`/jobs`, `/logs`, `/pghero`, …) y `/graphql` piden *basic auth*.
* Ambos hosts envían `X-Robots-Tag: noindex, nofollow`.
* Los usuarios semilla de PWB (contraseña pública `pwb123456`) quedan
  bloqueados y con contraseña aleatoria; el admin de CLARTO sale de `.env`.

## Sincronización Liberu → PWB

`rake pwb:liberu:sync` (servicio `pwb-sync`, cada `LIBERU_SYNC_INTERVAL` s).

* **Origen**: `GET /api/v1/public/properties` de Liberu, paginado. Solo
  devuelve estados `available` y `published`, así que **los borradores nunca
  salen** de Liberu.
* **Clave**: la referencia de Liberu (`CL-2026-00001`). La tabla
  `pwb_external_sync_records` tiene un índice único
  `(website, source, referencia)` y el inmueble se crea en la misma
  transacción que su registro, así que **un reintento no puede duplicar**. Si ya
  existe un inmueble de PWB con esa referencia, se adopta.
* **Idempotente**: compara *hashes* de datos y de fotos y, si no cambian, no
  escribe ni descarga nada. Un *advisory lock* impide dos ejecuciones a la vez.
* **Fotos**: se copian al almacenamiento de PWB (no se enlazan al backoffice),
  leyéndolas del volumen de Liberu montado en solo lectura. Solo se reordenan o
  borran las fotos que creó el sincronizador; las subidas a mano en PWB se
  respetan.
* **Retirada**: una referencia publicada que deja de aparecer en Liberu se
  oculta en PWB (anuncio `visible = false`); el inmueble y su historial se
  conservan. Si Liberu falla o devuelve la lista vacía, **no se retira nada**,
  salvo que se fuerce con `LIBERU_SYNC_ALLOW_EMPTY=true`.
* Mapeos: `deal_type` sale→venta y rent/daily→alquiler; superficie en ft²→m²;
  `property_type`→`types.*` de PWB; título y descripción en `es` y `en`.

Ejecución manual: `docker compose -p clarto-staging exec pwb-sync bundle exec rake pwb:liberu:sync`

## Copias de seguridad y restauración

* `scripts/backup.sh` → `/srv/clarto-staging/backups/<UTC>/`: volcado
  consistente de MySQL (`--single-transaction`), `pg_dump -Fc`, los volúmenes
  de fotos de ambas apps, `.env` y `secrets/` (sin ellos los datos no se pueden
  descifrar: `APP_KEY`, `SECRET_KEY_BASE`), un `manifest.txt` con recuentos y
  `SHA256SUMS`. Lo lanza el timer de systemd `clarto-backup.timer` cada día a las
  03:30, con retención de 14 días (`BACKUP_RETENTION_DAYS`).
* `scripts/restore-test.sh [dir]` restaura la copia en un proyecto Compose
  aparte, arranca ambas apps sobre esos datos, compara los recuentos con el
  manifiesto, verifica la integridad (MD5) de cada foto de PWB y lo borra todo.
  **No toca el entorno vivo.**
* `scripts/restore.sh <dir> --yes [--with-env]` restaura sobre el entorno vivo
  (para las apps, sustituye las bases de datos y los volúmenes y vuelve a
  arrancar).

```bash
scripts/backup.sh
scripts/restore-test.sh                                   # usa backups/latest
scripts/restore.sh /srv/clarto-staging/backups/<UTC> --yes --with-env
```

## Pruebas

* `scripts/e2e-flow.sh`: flujo completo con un inmueble ficticio a través de
  las interfaces reales (API REST de Liberu, sincronizador y catálogo por HTTPS
  vía Caddy). Deja el log en `state/e2e-*.log`.
* `.github/workflows/clarto-staging.yml`: ensaya en un runner limpio de
  Ubuntu 24.04 el despliegue completo, el E2E, el backup, la prueba de
  restauración aislada y una restauración en vivo, además de los specs del
  conector (`spec/services/pwb/liberu_sync`).
