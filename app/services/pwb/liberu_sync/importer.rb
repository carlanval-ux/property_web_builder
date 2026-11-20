# frozen_string_literal: true

require "digest"
require "set"

module Pwb
  module LiberuSync
    # Mirrors Liberu's public properties into one PWB website, keyed by the
    # Liberu property reference (e.g. "RE-2026-00042").
    #
    # Guarantees:
    # - Idempotent: re-running with the same Liberu data writes nothing
    #   (payload and photo digests are compared first).
    # - No duplicates: pwb_external_sync_records has a unique index on
    #   (website_id, source, external_reference); the RealtyAsset is created in
    #   the same transaction as its sync record, so a failed or retried run
    #   cannot leave a second asset behind. A pre-existing asset with the same
    #   reference is adopted rather than duplicated.
    # - Single runner: a Postgres advisory lock makes overlapping runs exit.
    # - Safe withdrawals: nothing is unpublished unless the complete Liberu
    #   listing was fetched; an empty listing never unpublishes unless
    #   allow_empty is set.
    # - Photos are owned per record (photo_map): only photos this importer
    #   created are reordered or removed; photos added by hand in PWB stay.
    class Importer
      SOURCE = "liberu"
      LOCK_KEY = 7_311_942_010 # arbitrary, stable advisory-lock id for this importer
      SQFT_TO_M2 = 0.09290304
      LOCALES = %i[es en].freeze

      TYPE_KEYS = {
        "apartment" => "types.apartment",
        "condo" => "types.apartment",
        "house" => "types.detached_house",
        "townhouse" => "types.townhouse",
        "villa" => "types.villa",
        "cottage" => "types.country_house",
        "commercial" => "types.commercial",
        "land" => "types.land",
        "development" => "types.residential_building",
        "new_build" => "types.residential_building"
      }.freeze

      Result = Struct.new(:created, :updated, :unchanged, :withdrawn, :republished, :photos_added,
                          :photos_removed, :errors, :skipped_withdrawals, keyword_init: true) do
        def to_h
          super.merge(errors: errors.map(&:to_s))
        end
      end

      class AlreadyRunning < StandardError; end

      def initialize(website:, client:, photo_fetcher: PhotoFetcher.new, allow_empty: false, logger: Rails.logger)
        @website = website
        @client = client
        @photo_fetcher = photo_fetcher
        @allow_empty = allow_empty
        @logger = logger
        @result = Result.new(created: [], updated: [], unchanged: [], withdrawn: [], republished: [],
                             photos_added: 0, photos_removed: 0, errors: [], skipped_withdrawals: false)
      end

      def call
        items = @client.fetch_all # raises FetchError before any write

        with_lock do
          seen = Set.new
          items.each do |item|
            reference = item["reference"].to_s.strip
            if reference.blank?
              @result.errors << "Liberu item id=#{item['id'].inspect} has no reference; skipped"
              next
            end
            if seen.include?(reference)
              @result.errors << "Duplicate reference #{reference} in Liberu listing; second copy skipped"
              next
            end

            seen << reference
            sync_item(reference, item)
          rescue StandardError => e
            @result.errors << "#{reference}: #{e.class}: #{e.message}"
            @logger.error("[LiberuSync] #{reference}: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
          end

          withdraw_missing(seen, items.empty?)
        end

        refresh_catalog
        @result
      end

      private

      def records
        Pwb::ExternalSyncRecord.where(website_id: @website.id, source: SOURCE)
      end

      # -- per item -------------------------------------------------------------

      def sync_item(reference, item)
        record = records.find_or_initialize_by(external_reference: reference)
        payload_digest = digest(canonical_payload(item))
        photos = gallery(item)
        photos_digest = digest(photos)
        asset = record.realty_asset || Pwb::RealtyAsset.find_by(website_id: @website.id, reference: reference)
        was_withdrawn = record.state == "withdrawn"

        if record.persisted? && asset && !was_withdrawn &&
           record.payload_digest == payload_digest && record.photos_digest == photos_digest
          record.update_column(:last_seen_at, Time.current)
          @result.unchanged << reference
          return
        end

        new_asset = asset.nil?
        payload_changed = new_asset || was_withdrawn || record.payload_digest != payload_digest

        if payload_changed
          ActiveRecord::Base.transaction do
            asset ||= Pwb::RealtyAsset.new(website: @website)
            asset.assign_attributes(asset_attributes(reference, item))
            asset.save!
            upsert_listing(asset, item)

            record.assign_attributes(realty_asset: asset, payload_digest: payload_digest, state: "published",
                                     withdrawn_at: nil, last_seen_at: Time.current)
            record.save!
          end
        else
          record.update!(last_seen_at: Time.current)
        end

        sync_photos(record, asset, photos, photos_digest) if record.photos_digest != photos_digest

        if new_asset then @result.created << reference
        elsif was_withdrawn then @result.republished << reference
        else @result.updated << reference
        end
      end

      def canonical_payload(item)
        item.except("gallery", "views_count", "price_usd", "id").sort.to_h
      end

      def gallery(item)
        Array(item["gallery"]).filter_map do |entry|
          url = entry["url"].to_s
          next if url.blank?

          { "url" => url, "caption" => entry["caption"].presence, "kind" => entry["kind"] }
        end
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(value))
      end

      def asset_attributes(reference, item)
        area_sqft = item["area_sqft"].presence&.to_f
        {
          reference: reference,
          title: item["title"].presence || reference,
          description: item["description"],
          street_address: item["address"],
          city: item["city"],
          region: item["region"],
          latitude: item["latitude"],
          longitude: item["longitude"],
          count_bedrooms: item["bedrooms"].to_i,
          count_bathrooms: item["bathrooms"].to_f,
          constructed_area: area_sqft ? (area_sqft * SQFT_TO_M2).round(2) : 0.0,
          prop_type_key: TYPE_KEYS[item["property_type"].to_s]
        }
      end

      def upsert_listing(asset, item)
        deal_type = item["deal_type"].presence || "sale"
        price_cents = item["price"].present? ? (BigDecimal(item["price"].to_s) * 100).round.to_i : 0
        currency = item["currency"].presence&.upcase || "EUR"

        if deal_type == "sale"
          hide_listings(asset.rental_listings)
          listing = asset.sale_listings.find_by(active: true) || asset.sale_listings.build
          listing.assign_attributes(active: true, visible: true, archived: false,
                                    price_sale_current_cents: price_cents, price_sale_current_currency: currency)
        else
          hide_listings(asset.sale_listings)
          listing = asset.rental_listings.find_by(active: true) || asset.rental_listings.build
          listing.assign_attributes(active: true, visible: true, archived: false,
                                    for_rent_long_term: deal_type == "rent", for_rent_short_term: deal_type == "daily",
                                    price_rental_monthly_current_cents: price_cents,
                                    price_rental_monthly_current_currency: currency)
        end

        LOCALES.each do |locale|
          Mobility.with_locale(locale) do
            listing.title = item["title"].presence || asset.reference
            listing.description = item["description"]
          end
        end
        listing.save!
      end

      def hide_listings(scope)
        scope.where(visible: true).find_each { |listing| listing.update!(visible: false) }
      end

      # -- photos -----------------------------------------------------------------

      def sync_photos(record, asset, photos, photos_digest)
        previous = Array(record.photo_map).index_by { |entry| entry["url"] }
        new_map = []

        photos.each_with_index do |photo, index|
          entry = previous[photo["url"]]
          prop_photo = entry && asset.prop_photos.find_by(id: entry["prop_photo_id"])

          unless prop_photo
            fetched = @photo_fetcher.fetch(photo["url"])
            prop_photo = Pwb::PropPhoto.new(realty_asset: asset)
            prop_photo.image.attach(io: fetched.io, filename: fetched.filename, content_type: fetched.content_type)
            @result.photos_added += 1
          end

          prop_photo.sort_order = index + 1
          prop_photo.description = photo["caption"]
          prop_photo.save! if prop_photo.new_record? || prop_photo.changed?
          new_map << { "url" => photo["url"], "prop_photo_id" => prop_photo.id }
        end

        removed_ids = previous.values.map { |entry| entry["prop_photo_id"] } - new_map.map { |entry| entry["prop_photo_id"] }
        if removed_ids.any?
          asset.prop_photos.where(id: removed_ids).find_each(&:destroy!)
          @result.photos_removed += removed_ids.size
        end

        record.update!(photo_map: new_map, photos_digest: photos_digest)
      end

      # -- withdrawals ----------------------------------------------------------

      def withdraw_missing(seen, listing_empty)
        missing = records.published.where.not(external_reference: seen.to_a)
        return unless missing.exists?

        if listing_empty && !@allow_empty
          @result.skipped_withdrawals = true
          @logger.warn("[LiberuSync] Liberu returned 0 public properties; refusing to unpublish #{missing.count} " \
                       "(set LIBERU_SYNC_ALLOW_EMPTY=true to allow)")
          return
        end

        missing.find_each do |record|
          ActiveRecord::Base.transaction do
            if (asset = record.realty_asset)
              hide_listings(asset.sale_listings)
              hide_listings(asset.rental_listings)
            end
            record.update!(state: "withdrawn", withdrawn_at: Time.current)
          end
          @result.withdrawn << record.external_reference
        rescue StandardError => e
          @result.errors << "#{record.external_reference} (withdraw): #{e.class}: #{e.message}"
        end
      end

      # -- infrastructure -------------------------------------------------------

      def with_lock
        connection = ActiveRecord::Base.connection
        locked = connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
        raise AlreadyRunning, "another Liberu sync is running" unless locked

        begin
          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{LOCK_KEY})")
        end
      end

      # The model callbacks enqueue a debounced async refresh; refresh
      # synchronously as well so the catalog is consistent when the run ends.
      def refresh_catalog
        Pwb::ListedProperty.refresh(concurrently: false)
        CacheService.invalidate_property_caches(@website.id) if defined?(CacheService)
      rescue StandardError => e
        @result.errors << "catalog refresh: #{e.class}: #{e.message}"
      end
    end
  end
end
