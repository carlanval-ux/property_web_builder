#!/usr/bin/env bash
# Prepare (or re-activate) an administrator of the panel (CLARTO Gestión
# Inmobiliaria) without handing anyone a password: the account gets a random
# unusable password and this prints a one-time "choose your password" link
# (valid 60 minutes). Run it on the server; open the link yourself.
#
#   scripts/panel-admin.sh persona@clarto.es "Nombre Apellido"
source "$(dirname "$0")/lib.sh"
require_env_file

email="${1:?usage: panel-admin.sh <email> [name]}"
name="${2:-Administración CLARTO}"

dc exec -T -u www-data \
  -e ADMIN_EMAIL="$email" -e ADMIN_NAME="$name" \
  liberu-app php artisan tinker --execute='
    $email = getenv("ADMIN_EMAIL"); $name = getenv("ADMIN_NAME");
    $model = config("auth.providers.users.model");
    $team = \Liberu\Foundation\Organizations\Models\Team::query()->oldest()->firstOrFail();
    $user = $model::firstOrNew(["email" => $email]);
    $user->forceFill([
        "name" => $user->name ?: $name,
        "password" => \Illuminate\Support\Facades\Hash::make(\Illuminate\Support\Str::random(64)),
        "email_verified_at" => $user->email_verified_at ?: now(),
        "current_team_id" => $team->id,
    ])->save();
    $user->teams()->syncWithoutDetaching([$team->id]);
    setPermissionsTeamId($team->id);
    $user->assignRole(\Spatie\Permission\Models\Role::findByName("super_admin", "web"));
    $token = \Illuminate\Support\Facades\Password::broker()->createToken($user);
    echo "ADMIN_READY ".$user->email.PHP_EOL;
    echo "LINK ".route("password.reset", ["token" => $token, "email" => $user->email]).PHP_EOL;
  ' | grep -E '^(ADMIN_READY|LINK) ' || die "could not prepare the administrator (see output above)"

log "Open the LINK above within 60 minutes, choose a password, then sign in at https://${LIBERU_HOST}/admin/login"
