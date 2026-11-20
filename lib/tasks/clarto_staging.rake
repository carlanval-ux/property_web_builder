# frozen_string_literal: true

# CLARTO staging: Liberu Real Estate is the source of truth for properties and
# this PWB instance is the public catalog. See deploy/clarto-staging/README.md.

module ClartoStaging
  module_function

  def env!(name)
    ENV.fetch(name) { abort "Missing required environment variable #{name}" }
  end

  def target_website!
    host = env!("PWB_HOST").downcase
    Pwb::Website.find_by_custom_domain(host) || abort("No PWB website for #{host}; run pwb:clarto_staging:bootstrap first")
  end

  def with_website(website)
    Pwb::Current.website = website
    ActsAsTenant.with_tenant(website) { yield }
  ensure
    Pwb::Current.website = nil
  end
end

namespace :pwb do
  namespace :liberu do
    desc "Sync Liberu public properties into the PWB catalog, keyed by reference (idempotent)"
    task sync: :environment do
      website = ClartoStaging.target_website!
      client = Pwb::LiberuSync::Client.new(base_url: ClartoStaging.env!("LIBERU_API_URL"))
      allow_empty = ENV["LIBERU_SYNC_ALLOW_EMPTY"] == "true"

      result = ClartoStaging.with_website(website) do
        Pwb::LiberuSync::Importer.new(website: website, client: client, allow_empty: allow_empty).call
      end

      summary = result.to_h.merge(at: Time.current.iso8601, website: website.custom_domain)
      puts "[liberu-sync] #{summary.to_json}"
      exit(1) if result.errors.any?
    rescue Pwb::LiberuSync::Importer::AlreadyRunning => e
      puts "[liberu-sync] skipped: #{e.message}"
    rescue Pwb::LiberuSync::FetchError => e
      warn "[liberu-sync] Liberu unreachable, nothing changed: #{e.message}"
      exit(2)
    end
  end

  namespace :clarto_staging do
    desc "Create or update the CLARTO staging website, its admin and seed data (idempotent)"
    task bootstrap: :environment do
      host = ClartoStaging.env!("PWB_HOST").downcase
      admin_email = ClartoStaging.env!("PWB_ADMIN_EMAIL")
      admin_password = ClartoStaging.env!("PWB_ADMIN_PASSWORD")

      load Rails.root.join("db/seeds/plans_seeds.rb")
      Pwb::PlansSeeder.seed!
      settings = Pwb::TenantSettings.instance
      settings.update!(default_available_themes: %w[default brisbane bologna]) if settings.default_available_themes.blank?

      website = Pwb::Website.find_by_custom_domain(host) || Pwb::Website.find_by_subdomain("clarto") ||
                Pwb::Website.new(subdomain: "clarto", theme_name: "default")
      website.assign_attributes(custom_domain: host, custom_domain_verified: true,
                                custom_domain_verified_at: website.custom_domain_verified_at || Time.current,
                                default_client_locale: "es", default_currency: "EUR", default_area_unit: "sqmt")
      website.save!
      website.update_column(:provisioning_state, "live")

      ClartoStaging.with_website(website) do
        unless website.pages.exists?
          Pwb::Seeder.seed!(website: website, skip_properties: true)
          Pwb::PagesSeeder.seed_page_basics!(website: website)
          Pwb::PagesSeeder.seed_page_parts!(website: website)
        end

        # The stock seed users ship with a published password; neutralise them.
        seeded_emails = YAML.load_file(Rails.root.join("db/yml_seeds/users.yml")).map { |u| u["email"] }.compact
        Pwb::User.where(email: seeded_emails).where.not(email: admin_email).find_each do |user|
          user.update!(password: SecureRandom.base58(48), locked_at: Time.current)
        end

        admin = Pwb::User.find_or_initialize_by(email: admin_email)
        admin.assign_attributes(password: admin_password, website: website, admin: true,
                                confirmed_at: admin.confirmed_at || Time.current, locked_at: nil, failed_attempts: 0)
        admin.save!
        membership = Pwb::UserMembership.find_or_initialize_by(user: admin, website: website)
        membership.update!(role: "owner", active: true)
      end

      puts "[bootstrap] website ##{website.id} https://#{host} ready; admin #{admin_email}"
    end
  end
end
