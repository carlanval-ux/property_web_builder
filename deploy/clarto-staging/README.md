# CLARTO — staging (VPS OVH)

Panel interno **CLARTO Gestión Inmobiliaria** (Liberu, con la identidad de CLARTO) y **vista previa** de la web
con el catálogo `clarto.es/inmuebles`. Docker Compose sobre un único VPS, HTTPS automático (Let's Encrypt
con renovación) y despliegue reproducible desde esta rama (`staging/clarto` del fork de PWB).

| URL | Qué es | Acceso |
|---|---|---|
| https://panel.clarto.es | Panel del equipo (Filament) | inicio de sesión en **cualquier** URL; sin registro público |
| https://panel.clarto.es/buzon/ | Buzón de pruebas (Mailpit): todo el correo saliente de staging | basic auth de operación |
| https://panel.clarto.es/api/v1/catalogo/* | API de catálogo de solo lectura | clave de servidor `X-Catalogo-Clave` |
| https://inmuebles-previa.clarto.es | Vista previa de la web (rama `feat/catalogo-inmuebles`) | abierta, `noindex` + `robots.txt` Disallow |
| ~~inmuebles.clarto.es~~ | PropertyWebBuilder | **en pausa** (perfil `pwb`, `ENABLE_PWB=true`) |

```
Equipo ─► panel.clarto.es ─(API catálogo, clave)─► servidor de la web ─► /inmuebles · /inmuebles/{ficha}
             Liberu + SQLite (volumen)                 (Lovable en producción; web-preview aquí)
```

## Servicios

`caddy` (TLS y proxy) · `liberu-app` (Apache + PHP 8.5), `liberu-worker` (cola Redis), `liberu-scheduler` ·
`redis` · `mailpit` · `web-preview` (TanStack Start en Node; solo si se ha subido la web).

Versiones fijadas: Liberu por SHA en `versions.env` (rama `staging/clarto` del fork `carlanval-ux/realstate`),
imágenes por etiqueta (`caddy:2.10.2`, `redis:7.4.5`, `axllent/mailpit:v1.27.10`, `php:8.5-apache-trixie`,
`node:22.18`, `oven/bun:1.4.2`), web por SHA de la rama (`src/web/.source-ref`).

## Despliegue

```bash
# Primera vez (Ubuntu limpio, usuario con sudo; Ploi ya instala Docker en «Docker Server»)
git clone -b staging/clarto https://github.com/carlanval-ux/property_web_builder.git /srv/clarto-staging/pwb
cd /srv/clarto-staging/pwb/deploy/clarto-staging
sudo scripts/install-host.sh "$USER"     # ufw 22/80/443, logs de Docker, actualizaciones
scripts/init-env.sh --liberu-host panel.clarto.es --pwb-host inmuebles.clarto.es   # .env y secrets/ (no se versionan)
scripts/deploy.sh                        # build + migraciones + semillas + identidad + arranque

# Actualizar
git pull && scripts/deploy.sh

# Web para la vista previa (desde un equipo con acceso al repositorio privado de la web)
scripts/upload-web.sh ../web feat/catalogo-inmuebles clarto-staging
ssh clarto-staging 'cd /srv/clarto-staging/pwb/deploy/clarto-staging && scripts/compose.sh build web-preview && scripts/compose.sh up -d web-preview'

# Operación
scripts/compose.sh ps | logs -f liberu-app | exec liberu-app php artisan about
```

Credenciales generadas: `secrets/credentials.txt` (modo 600, solo en el servidor). La clave del catálogo está en
`.env` (`CATALOGO_API_KEY`); en producción se configura como secreto de servidor en Lovable.

## Primer administrador del panel

No se reparte ninguna contraseña: el script crea (o reactiva) la cuenta con rol `super_admin` y muestra un
**enlace de un solo uso (60 min)** para que la persona elija su contraseña.

```bash
ssh clarto-staging
cd /srv/clarto-staging/pwb/deploy/clarto-staging
scripts/panel-admin.sh persona@clarto.es "Nombre Apellido"
# → abrir el LINK, elegir contraseña y entrar en https://panel.clarto.es/admin/login
```

«¿Olvidó su contraseña?» funciona, pero en staging el correo llega al buzón de pruebas (`/buzon/`).

## Decisiones y parches de staging (revisar con upstream)

* **Imágenes propias.** La de Liberu usa Octane/RoadRunner sin el binario `rr`; la de PWB falla en `bootsnap`.
* **SQLite** para el panel (WAL, en el volumen persistente).
* **Migraciones defectuosas en los módulos publicados** (Packagist): 6 migraciones alteran tablas que no existen
  o usan clases que el host no tiene. `liberu/patch-migrations.php` las envuelve y registra un aviso; el build
  falla si cambian. Hay que reportarlo a liberusoftware.
* **Modo interno** (`APP_STAFF_ONLY`): todas las URL exigen sesión, incluidas las públicas de los módulos
  registradas fuera del grupo `web`. Las fotos (`/storage`) se comprueban con `forward_auth`.
  Registro cerrado con `IDENTITY_REGISTRATION=closed`.
* **Identidad CLARTO**: logo, colores, tipografías, favicons y textos, sin marcas de terceros visibles (las
  licencias MIT se conservan en el código).
* **Superficie en m²**: el campo `area_sqft` se etiqueta «Superficie construida (m²)».

## Pruebas

* `scripts/e2e-catalogo.sh`: flujo completo con un inmueble ficticio. Último resultado: **37/37**. Cubre borrador
  fuera; publicar; precio; fotos (WebP firmadas); reservar; retirar (404 también por enlace directo y fotos sin
  servir); sin datos internos; sin duplicados; `noindex`.
* `scripts/demo-catalogo.sh [--retirar]`: dos anuncios ficticios para revisar la vista previa.

## Módulos

Inventario completo con versiones: [`MODULOS.md`](MODULOS.md). Resumen: el fork usa el mismo `composer.json` y
`composer.lock` que el proyecto oficial; los 78 módulos inmobiliarios (portales incluidos) están instalados y
cargados. «Modules» aparece vacío porque solo lista módulos `feature` y los oficiales son todos «infraestructura».

## Copias de seguridad

Política acordada: **backup automático del VPS de OVH** (diario, 18:40 UTC; la opción estándar guarda la última
copia). Además, antes de cada cambio de versión:

```bash
sudo scripts/backup.sh          # SQLite (VACUUM INTO) + volumen de ficheros + .env → /srv/clarto-staging/backups/<fecha>
sudo scripts/restore-test.sh    # restaura en un proyecto aislado, aplica migraciones y compara recuentos
```

## Volver atrás (rollback)

1. `git revert` del commit que cambió `versions.env` (o fijar el `LIBERU_REF` anterior) y `git push`.
2. En el servidor: `git pull && scripts/deploy.sh` (reconstruye la imagen anterior).
3. Si las migraciones nuevas cambiaron datos: `sudo scripts/restore.sh /srv/clarto-staging/backups/<fecha> --yes`.
