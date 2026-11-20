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
        Pwb::LiberuSync::Importer.new(website: website, client: client, allow_empty: allow_empty,
                                      test_label: ENV["CATALOG_TEST_LABEL"]).call
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

        # Public identity of the catalog and where enquiries go. In staging every
        # outgoing mail is captured by the test mailbox (Mailpit), whatever the
        # recipient, so nothing reaches a real inbox.
        brand = ENV.fetch("CATALOG_BRAND", "CLARTO Inmobiliaria")
        inquiry_email = ENV.fetch("CATALOG_INQUIRY_EMAIL", "buzon-pruebas@clarto.es")
        agency = website.agency || website.build_agency
        agency.assign_attributes(display_name: brand, company_name: brand, email_primary: inquiry_email,
                                 email_for_general_contact_form: inquiry_email,
                                 email_for_property_contact_form: inquiry_email)
        agency.save!
        website.update!(company_display_name: brand) if website.respond_to?(:company_display_name=)

        # CLARTO visual identity (colours/fonts from the brand guide, logo served
        # from /brand by the image) and no third-party product credit or links.
        style = (website.style_variables_for_theme || {}).deep_dup
        style["default"] = (style["default"] || Pwb::WebsiteStyleable::DEFAULT_STYLE_VARIABLES.dup).merge(
          "primary_color" => "#173D38",   # verde petróleo
          "secondary_color" => "#BD7968", # terracota
          "action_color" => "#9E5847",    # terracota texto (contraste AA sobre blanco)
          "font_primary" => "DM Sans",
          "font_secondary" => "Manrope",
          "border_radius" => "0.75rem"
        )
        website.update!(style_variables_for_theme: style, selected_palette: nil,
                        main_logo_url: "/brand/clarto-logo-color.png",
                        whitelabel_config: (website.whitelabel_config || {}).merge("show_powered_by" => false),
                        social_media: {})
        website.links.where(slug: Pwb::WebsiteSocialLinkable::SOCIAL_MEDIA_PLATFORMS.map { |p| "social_media_#{p}" })
               .find_each { |link| link.update_columns(link_url: nil, visible: false) }
        website.links.where("link_url ILIKE ?", "%propertywebbuilder%").find_each { |link| link.update!(visible: false) }

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
