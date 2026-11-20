# syntax=docker/dockerfile:1
# PropertyWebBuilder image for CLARTO staging (build context: repository root).
#
# Same stages as the repository's Dockerfile, minus `bootsnap precompile`:
# bootsnap is not in the Gemfile, so the upstream image fails at
# `bundle exec bootsnap` (exit 127) and cannot be built as is.
# Versions pinned to .tool-versions (ruby 3.4.7) and the upstream node stage.

FROM node:22.18-bookworm-slim AS node_builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY app/assets/stylesheets/ ./app/assets/stylesheets/
COPY app/themes/ ./app/themes/
COPY app/views/ ./app/views/
COPY app/helpers/ ./app/helpers/
COPY app/javascript/ ./app/javascript/
RUN npm run tailwind:build:prod

FROM ruby:3.4.7-slim-bookworm AS ruby_builder
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y build-essential git libpq-dev libvips-dev libyaml-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV RAILS_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT="development:test"
COPY Gemfile Gemfile.lock ./
RUN bundle install \
 && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

FROM ruby:3.4.7-slim-bookworm AS production
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y curl libpq5 libvips42 libyaml-0-2 postgresql-client \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --system --gid 1000 rails && useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
WORKDIR /app
ENV RAILS_ENV=production NODE_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" RAILS_LOG_TO_STDOUT=true RAILS_SERVE_STATIC_FILES=true
COPY --from=ruby_builder /usr/local/bundle /usr/local/bundle
COPY --from=node_builder /app/app/assets/builds/ ./app/assets/builds/
COPY . .
RUN SECRET_KEY_BASE=dummy_key_for_precompilation bundle exec rake assets:precompile \
 && mkdir -p tmp/pids tmp/cache tmp/sockets log storage \
 && chown -R rails:rails tmp log storage db
COPY docker-entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/docker-entrypoint.sh
USER rails
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 CMD curl -fsS -o /dev/null http://localhost:3000/up || exit 1
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
