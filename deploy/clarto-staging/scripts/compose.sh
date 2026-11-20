#!/usr/bin/env bash
# docker compose for this stack with the pinned refs and .env loaded.
#   scripts/compose.sh ps | logs -f liberu-app | exec liberu-app php artisan about ...
source "$(dirname "$0")/lib.sh"
require_env_file
dc "$@"
