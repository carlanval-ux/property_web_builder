require_relative "production"

Rails.application.configure do
  # Self-hosted staging (e.g. CLARTO, deploy/clarto-staging) keeps uploads on a
  # local Docker volume instead of Cloudflare R2: ACTIVE_STORAGE_SERVICE=local.
  # Unset, staging keeps production's R2 behaviour.
  config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "cloudflare_r2").to_sym

  # Use a dedicated host for staging emails and generated links.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("MAILER_HOST") do
      ENV.fetch("STAGING_APP_HOST") { ENV.fetch("APP_HOST", "staging.example.com") }
    end,
    protocol: ENV.fetch("STAGING_APP_PROTOCOL", "https")
  }
end
