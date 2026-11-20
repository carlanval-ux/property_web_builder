# syntax=docker/dockerfile:1
# Liberu Real Estate for CLARTO staging: php:8.5 + Apache (mod_php).
#
# The upstream image runs Laravel Octane on RoadRunner but never installs the
# `rr` binary, and its CI only builds the image (it is never started), so this
# staging image serves the same code with Apache instead. Source code comes
# from the `src` build context (scripts/fetch-sources.sh checks out LIBERU_REF).
ARG PHP_IMAGE=php:8.5-apache-trixie

FROM composer:2.8 AS composer

FROM ${PHP_IMAGE}
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip git \
 && install-php-extensions bcmath intl zip pdo_mysql pdo_pgsql gd exif pcntl sockets opcache redis igbinary \
 && rm -rf /var/lib/apt/lists/*

COPY --from=composer /usr/bin/composer /usr/bin/composer

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_FUND=0
RUN a2enmod rewrite headers remoteip \
 && sed -ri 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
 && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY apache-staging.conf /etc/apache2/conf-enabled/zz-staging.conf
COPY php-staging.ini "$PHP_INI_DIR/conf.d/zz-staging.ini"

WORKDIR /var/www/html
COPY patch-migrations.php /tmp/patch-migrations.php
COPY --from=src --chown=www-data:www-data . .
RUN rm -rf .git .env \
 && composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts \
 && php artisan package:discover --ansi \
 && php artisan filament:upgrade --ansi \
 && php /tmp/patch-migrations.php /var/www/html \
 && for d in modules/*/ themes/*/; do mkdir -p "${d}resources/views"; done \
 && mkdir -p storage/framework/sessions storage/framework/views storage/framework/cache storage/logs bootstrap/cache \
 && chown -R www-data:www-data storage bootstrap/cache

# CLARTO identity (build context "brand" = deploy/clarto-staging/brand)
COPY --from=brand --chown=www-data:www-data clarto-favicon.svg public/favicon.svg
COPY --from=brand --chown=www-data:www-data icon-32.png public/favicon-32.png
COPY --from=brand --chown=www-data:www-data clarto-logo-color.png clarto-logo-negativo.png clarto-simbolo.svg clarto-simbolo-negativo.svg icon-180.png icon-192.png icon-512.png public/brand/

COPY --chmod=0755 entrypoint.sh /usr/local/bin/liberu-entrypoint
ENTRYPOINT ["liberu-entrypoint"]
CMD ["apache2-foreground"]
