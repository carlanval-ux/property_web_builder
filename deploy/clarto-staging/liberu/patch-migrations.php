<?php

/*
 * CLARTO staging: neutralise known-broken upstream migrations at image build.
 *
 * The liberusoftware module versions that `composer install` resolves from
 * Packagist ship migrations that cannot run on a clean database:
 *   - ALTERs on tables no migration creates (contacts, tickets, social_media_posts…)
 *   - data backfills/seeds referencing host classes this composition does not have
 *     (App\Enums\Role, App\Support\PermissionCatalog)
 * Each listed migration gets its up() body wrapped in try/catch: whatever it can
 * do is done, a failure is logged as a warning, and the migration is recorded so
 * the rest of the chain runs. Only the files listed here are touched, and the
 * build fails if one of them is missing (i.e. upstream changed and this list
 * must be reviewed). Report upstream; remove entries as they get fixed.
 */

$root = $argv[1] ?? '/var/www/html';

$files = [
    'modules/organizations-teams/database/migrations/2024_09_29_093707_add_team_to_resources.php',
    'modules/organizations-teams/database/migrations/2024_11_17_000000_add_team_id_to-staff_resource_tables.php',
    'modules/organizations-teams/database/migrations/2026_07_07_120000_add_team_id_to_tickets_table.php',
    'modules/roles-permissions/database/migrations/2026_07_06_000003_backfill_role_assignment_teams.php',
    'modules/roles-permissions/database/migrations/2026_07_10_000100_seed_role_permissions.php',
    '*/database/migrations/2026_11_05_010000_create_marketing_platform_settings.php',
];

$exit = 0;
foreach ($files as $pattern) {
    $matches = glob($root.'/'.$pattern) ?: (str_starts_with($pattern, '*/') ? glob($root.'/modules/'.$pattern) : []);
    if ($matches === []) {
        fwrite(STDERR, "patch-migrations: not found: {$pattern}\n");
        $exit = 1;

        continue;
    }

    foreach ($matches as $file) {
        $src = file_get_contents($file);
        if (str_contains($src, 'CLARTO-PATCHED')) {
            continue;
        }

        if (! preg_match('/public function up\(\)\s*(?::\s*void)?\s*\{/', $src, $m, PREG_OFFSET_CAPTURE)) {
            fwrite(STDERR, "patch-migrations: no up() in {$file}\n");
            $exit = 1;

            continue;
        }

        $open = $m[0][1] + strlen($m[0][0]) - 1; // position of the "{"
        $depth = 0;
        $close = null;
        for ($i = $open, $n = strlen($src); $i < $n; $i++) {
            if ($src[$i] === '{') {
                $depth++;
            } elseif ($src[$i] === '}') {
                $depth--;
                if ($depth === 0) {
                    $close = $i;
                    break;
                }
            }
        }
        if ($close === null) {
            fwrite(STDERR, "patch-migrations: unbalanced braces in {$file}\n");
            $exit = 1;

            continue;
        }

        $name = basename($file, '.php');
        $body = substr($src, $open + 1, $close - $open - 1);
        $wrapped = "\n        // CLARTO-PATCHED: see deploy/clarto-staging/liberu/patch-migrations.php\n        try {"
            .$body
            ."} catch (\\Throwable \$e) {\n"
            ."            \\Illuminate\\Support\\Facades\\Log::warning('CLARTO staging: upstream migration step skipped', ['migration' => '{$name}', 'error' => \$e->getMessage()]);\n"
            ."        }\n    ";
        file_put_contents($file, substr($src, 0, $open + 1).$wrapped.substr($src, $close));
        echo "patched {$name}\n";
    }
}

exit($exit);
