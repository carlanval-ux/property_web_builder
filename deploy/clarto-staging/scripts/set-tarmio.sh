#!/usr/bin/env bash
# Connects Liberu to TARMIO (the team's task app) with the integration user. The password is typed here, on the
# server, and only stored in .env (mode 600); it is never printed. TARMIO's Supabase URL and publishable key are
# public (they ship in tarmio.app itself), so they are defaults here.
#
#   scripts/set-tarmio.sh <correo-del-usuario-de-integracion>   # type the password; finds the CLARTO company, checks
#   scripts/set-tarmio.sh --test                                 # sign in and check permissions (creates nothing)
#   scripts/set-tarmio.sh --prueba                               # --test + create one fictitious task and delete it
#   scripts/set-tarmio.sh --proyecto <uuid>|bandeja              # project for Liberu tasks (default: company inbox)
#   scripts/set-tarmio.sh --responsable <correo>                 # who gets «nuevo propietario» (default: team owner)
#   scripts/set-tarmio.sh --activar | --desactivar               # TARMIO_DRIVER=http | simulado (real sends on/off)
#   scripts/set-tarmio.sh --off                                  # forget the credentials (back to simulated)
#
# Saving the credentials does NOT turn real sends on: Liberu keeps TARMIO_DRIVER=simulado until --activar.
source "$(dirname "$0")/lib.sh"
require_env_file

DEFAULT_URL="https://qqwikylpxwscagwuwwbh.supabase.co"          # TARMIO production (tarmio.app)
DEFAULT_KEY="sb_publishable_eWU8iMgdilgJpM2D30pgjg_3x363Yol"     # publishable key, public in tarmio.app

set_env() { # set_env KEY VALUE (replace or append, value kept literal)
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"; grep -v "^${key}=" "$BUNDLE_DIR/.env" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$BUNDLE_DIR/.env"; rm -f "$tmp"; chmod 600 "$BUNDLE_DIR/.env"
}
env_value() { grep -E "^$1=" "$BUNDLE_DIR/.env" | tail -1 | cut -d= -f2- | sed "s/^'\(.*\)'$/\1/" || true; }
restart() { dc up -d --force-recreate liberu-app liberu-worker liberu-scheduler >/dev/null; sleep 5; }

# tarmio <mode>: talks to TARMIO from inside the panel container with the stored credentials (getenv), so the
# password never appears in a command line. Modes: empresas | comprobar | prueba. Prints only results.
tarmio() {
  dc exec -T -u www-data liberu-app php -- "$1" <<'PHP'
<?php
$mode = $argv[1] ?? 'comprobar';
$url = rtrim((string) getenv('TARMIO_SUPABASE_URL'), '/');
$key = (string) getenv('TARMIO_SUPABASE_KEY');
$org = (string) getenv('TARMIO_ORGANIZATION_ID');
$project = (string) getenv('TARMIO_PROJECT_ID');
$owner = strtolower(trim((string) getenv('TARMIO_RESPONSABLE_CAPTACION')));
$token = null;
$fail = false;

function call(string $method, string $path, ?array $body = null, array $extra = []): array {
    global $url, $key, $token;
    $headers = array_merge(['apikey: '.$key, 'Accept: application/json', 'Content-Type: application/json'], $extra);
    if ($token) { $headers[] = 'Authorization: Bearer '.$token; }
    $c = curl_init($url.$path);
    curl_setopt_array($c, [CURLOPT_CUSTOMREQUEST => $method, CURLOPT_HTTPHEADER => $headers,
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 20]);
    if ($body !== null) { curl_setopt($c, CURLOPT_POSTFIELDS, json_encode($body)); }
    $raw = curl_exec($c);
    $code = (int) curl_getinfo($c, CURLINFO_HTTP_CODE);
    $error = curl_error($c);
    if ($raw === false) { return [0, ['message' => $error]]; }
    return [$code, json_decode((string) $raw, true)];
}
function say(string $level, string $text): void { global $fail; if ($level === 'ERROR') { $fail = true; } echo $level.' '.$text.PHP_EOL; }
function why($json): string { return is_array($json) ? (string) ($json['message'] ?? $json['msg'] ?? $json['error_description'] ?? json_encode($json)) : ''; }
function q(string $v): string { return rawurlencode($v); }

// 1. Sign in (password grant). TARMIO has no API tokens.
[$code, $s] = call('POST', '/auth/v1/token?grant_type=password', ['email' => getenv('TARMIO_USUARIO'), 'password' => getenv('TARMIO_PASSWORD')]);
if ($code !== 200 || empty($s['access_token'])) {
    say('ERROR', $code === 400 ? 'TARMIO no acepta el usuario o la contraseña (o el correo aún no está confirmado)' : "no se pudo iniciar sesión en TARMIO ($code: ".why($s).')');
    exit(1);
}
$token = $s['access_token'];
$uid = $s['user']['id'] ?? '';
foreach ($s['user']['factors'] ?? [] as $f) {
    if (($f['status'] ?? '') === 'verified') { say('ERROR', 'el usuario de integración tiene la verificación en dos pasos activada: TARMIO le negará el acceso a la empresa. Quítasela en TARMIO'); }
}
say('OK', 'sesión iniciada en TARMIO como '.getenv('TARMIO_USUARIO'));

// 2. Companies the user belongs to (the integration user should only be in CLARTO).
[$code, $orgs] = call('GET', '/rest/v1/organizations?select=id,name&order=name');
if ($code !== 200) { say('ERROR', "no se pudieron leer las empresas ($code: ".why($orgs).')'); exit(1); }
if ($mode === 'empresas') { foreach ($orgs as $o) { echo "EMPRESA\t{$o['id']}\t{$o['name']}".PHP_EOL; } exit(0); }

$name = null;
foreach ($orgs as $o) { if ($o['id'] === $org) { $name = $o['name']; } }
if ($name === null) { say('ERROR', 'el usuario no es miembro de la empresa configurada (TARMIO_ORGANIZATION_ID)'); exit(1); }

[$code, $m] = call('GET', '/rest/v1/organization_memberships?select=role&organization_id=eq.'.q($org).'&user_id=eq.'.q($uid));
$role = $m[0]['role'] ?? null;
if (in_array($role, ['owner', 'admin', 'manager'], true)) { say('OK', "miembro de «{$name}» con rol {$role}"); }
else { say('ERROR', "en «{$name}» tiene rol ".($role ?? 'desconocido').': hace falta Manager para actualizar tareas reasignadas'); }

// 3. Task columns Liberu uses (PostgREST rejects unknown columns even when no row is visible).
[$code, $t] = call('GET', '/rest/v1/tasks?select=id,public_ref,title,description,due_date,assignee_id,created_by,project_id,source_provider,source_external_id&organization_id=eq.'.q($org).'&limit=1');
$code === 200 ? say('OK', 'la tabla de tareas tiene los campos que usa Liberu') : say('ERROR', "tabla de tareas: $code ".why($t));

// 4. Project (optional) and the list to choose from.
[$code, $ps] = call('GET', '/rest/v1/projects?select=id,name&archived_at=is.null&is_template=eq.false&organization_id=eq.'.q($org).'&order=name');
if ($project !== '') {
    $found = array_values(array_filter(is_array($ps) ? $ps : [], fn ($p) => $p['id'] === $project));
    $found ? say('OK', "las tareas irán al proyecto «{$found[0]['name']}»") : say('ERROR', 'TARMIO_PROJECT_ID no es un proyecto activo de la empresa (o el usuario no lo ve)');
} else {
    say('OK', 'las tareas irán a la bandeja de la empresa (sin proyecto)');
    foreach (is_array($ps) ? $ps : [] as $p) { echo "PROYECTO\t{$p['id']}\t{$p['name']}".PHP_EOL; }
}

// 5. Owner of «nuevo propietario» tasks: must be a member of the company with the same e-mail.
if ($owner !== '') {
    [$code, $pr] = call('GET', '/rest/v1/profiles?select=id,email&email=ilike.'.q($owner));
    $ids = array_column(array_filter(is_array($pr) ? $pr : [], fn ($p) => strtolower((string) $p['email']) === $owner), 'id');
    [$code, $mm] = $ids ? call('GET', '/rest/v1/organization_memberships?select=user_id&organization_id=eq.'.q($org).'&user_id=in.('.implode(',', array_map('q', $ids)).')') : [200, []];
    ! empty($mm) ? say('OK', "responsable de altas encontrado en TARMIO: $owner")
        : say('AVISO', "$owner no es miembro de «{$name}» en TARMIO: esas tareas se crearán sin asignar");
}

// 6. Optional round trip: one fictitious task, deleted straight away.
if ($mode === 'prueba' && ! $fail) {
    [$code, $rows] = call('POST', '/rest/v1/tasks', array_filter([
        'organization_id' => $org, 'project_id' => $project ?: null, 'created_by' => $uid,
        'title' => 'Prueba de conexión desde Liberu (se borra sola)',
        'source_provider' => 'liberu', 'source_external_id' => 'prueba:conexion:'.time(),
    ]), ['Prefer: return=representation']);
    $id = $rows[0]['id'] ?? null;
    if (! $id) { say('ERROR', "no se pudo crear la tarea de prueba ($code: ".why($rows).')'); exit(1); }
    $ref = $rows[0]['public_ref'] ?? $id;
    say('OK', "tarea de prueba creada ($ref)");
    [$code, $del] = call('DELETE', '/rest/v1/tasks?id=eq.'.q($id), null, ['Prefer: return=representation']);
    ($code === 200 && ! empty($del)) ? say('OK', "tarea de prueba $ref borrada")
        : say('ERROR', "no se pudo borrar la tarea de prueba $ref ($code): bórrala a mano en TARMIO");
}
exit($fail ? 1 : 0);
PHP
}

check() { # check [comprobar|prueba]: prints the results; fails if something blocks real sends
  local out status=0
  out="$(tarmio "${1:-comprobar}" 2>&1)" || status=$?
  printf '%s\n' "$out" | grep -E '^(OK|AVISO|ERROR) ' | sed 's/^/  /' || true
  if printf '%s\n' "$out" | grep -q '^PROYECTO'; then
    echo "  Proyectos de la empresa (opcional: scripts/set-tarmio.sh --proyecto <id>):"
    printf '%s\n' "$out" | awk -F'\t' '/^PROYECTO/{printf "    %s  %s\n", $2, $3}'
  fi
  printf '%s\n' "$out" | grep -qE '^(OK|AVISO|ERROR) ' || { printf '%s\n' "$out" | tail -5 >&2; status=1; }
  [ "$status" -eq 0 ] || die "la conexión con TARMIO no está lista (ver arriba)"
  if [ "$(env_value TARMIO_DRIVER)" = http ]; then log "TARMIO listo. Envíos reales: ACTIVADOS"
  else log "TARMIO listo. Envíos reales: desactivados (se activan con --activar)"; fi
}

case "${1:-}" in
  --test) check comprobar; exit 0 ;;
  --prueba) check prueba; exit 0 ;;
  --proyecto)
    p="${2:?uso: set-tarmio.sh --proyecto <uuid>|bandeja}"
    if [ "$p" = bandeja ]; then set_env TARMIO_PROJECT_ID ""
    else [[ "$p" =~ ^[0-9a-f-]{36}$ ]] || die "eso no parece el id de un proyecto"; set_env TARMIO_PROJECT_ID "$p"; fi
    restart; check comprobar; exit 0 ;;
  --responsable)
    r="${2:?uso: set-tarmio.sh --responsable <correo>}"
    [[ "$r" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "eso no parece un correo"
    set_env TARMIO_RESPONSABLE_CAPTACION "$r"; restart; check comprobar; exit 0 ;;
  --activar)
    check comprobar
    set_env TARMIO_DRIVER http; restart
    log "envíos reales ACTIVADOS: las acciones pendientes de Liberu se crean en TARMIO en la siguiente sincronización"; exit 0 ;;
  --desactivar)
    set_env TARMIO_DRIVER simulado; restart; log "envíos reales desactivados (Liberu vuelve a simular)"; exit 0 ;;
  --off)
    set_env TARMIO_DRIVER simulado
    for k in TARMIO_USUARIO TARMIO_PASSWORD TARMIO_ORGANIZATION_ID TARMIO_PROJECT_ID; do set_env "$k" ""; done
    sed -i '/^TARMIO_\(USUARIO\|PASSWORD\|ORGANIZATION_ID\|PROJECT_ID\)=$/d' "$BUNDLE_DIR/.env"
    restart; log "credenciales de TARMIO borradas; Liberu vuelve a simular"; exit 0 ;;
  -*) die "opción desconocida: $1" ;;
esac

user="${1:?uso: set-tarmio.sh <correo-del-usuario-de-integracion>  (o --test, --prueba, --proyecto, --responsable, --activar)}"
[[ "$user" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "eso no parece un correo"
[ -t 0 ] || die "ejecútalo en una terminal interactiva: la contraseña se lee del teclado"
read -r -s -p "Contraseña de $user en TARMIO (no se muestra): " pass; echo
[ -n "$pass" ] || die "contraseña vacía"
case "$pass" in *"'"*) die "la contraseña lleva una comilla simple, que .env no puede guardar tal cual; cámbiala en TARMIO" ;; esac

[ -n "$(env_value TARMIO_SUPABASE_URL)" ] || set_env TARMIO_SUPABASE_URL "$DEFAULT_URL"
[ -n "$(env_value TARMIO_SUPABASE_KEY)" ] || set_env TARMIO_SUPABASE_KEY "$DEFAULT_KEY"
[ -n "$(env_value TARMIO_DRIVER)" ] || set_env TARMIO_DRIVER simulado
set_env TARMIO_USUARIO "$user"
set_env TARMIO_PASSWORD "'$pass'"   # single quotes: compose does not interpolate $ in them
unset pass
restart

# Find the CLARTO company among the user's companies (normally it belongs only to CLARTO).
empresas="$(tarmio empresas 2>&1)" || {
  printf '%s\n' "$empresas" | grep -E '^ERROR ' >&2 || printf '%s\n' "$empresas" | tail -5 >&2
  die "credenciales guardadas, pero TARMIO no deja entrar: revisa el usuario y vuelve a ejecutarlo"
}
lista="$(printf '%s\n' "$empresas" | grep '^EMPRESA' || true)"
actual="$(env_value TARMIO_ORGANIZATION_ID)"
if [ -n "$actual" ] && printf '%s\n' "$lista" | cut -f2 | grep -qx "$actual"; then org="$actual"
elif [ "$(printf '%s\n' "$lista" | grep -c .)" -eq 1 ]; then org="$(printf '%s\n' "$lista" | cut -f2)"
else org="$(printf '%s\n' "$lista" | awk -F'\t' 'tolower($3) ~ /clarto/' | cut -f2)"; fi
if [ -z "$org" ] || [ "$(printf '%s\n' "$org" | grep -c .)" -ne 1 ]; then
  printf '%s\n' "$lista" | awk -F'\t' 'NF{printf "    %s  %s\n", $2, $3}' >&2
  die "no sé cuál es la empresa CLARTO: el usuario debe ser miembro solo de CLARTO (o pon TARMIO_ORGANIZATION_ID en .env)"
fi
if [ "$org" != "$actual" ]; then set_env TARMIO_ORGANIZATION_ID "$org"; restart; fi
log "empresa TARMIO: $(printf '%s\n' "$lista" | awk -F'\t' -v id="$org" '$2==id{print $3}') ($org)"
check comprobar
