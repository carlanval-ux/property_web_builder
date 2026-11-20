# frozen_string_literal: true

require "rails_helper"

RSpec.describe Pwb::LiberuSync::Importer, type: :service do
  let(:website) { create(:pwb_website) }

  # 1x1 PNG
  let(:png) { Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") }

  let(:fake_fetcher) do
    bytes = png
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:fetch) do |url|
        @calls << url
        Pwb::LiberuSync::PhotoFetcher::Photo.new(io: StringIO.new(bytes), filename: File.basename(url), content_type: "image/png")
      end
    end.new
  end

  def item(reference: "RE-2026-00042", price: "250000.00", deal_type: "sale", gallery: nil, title: "Piso CLARTO de prueba")
    {
      "id" => 42, "reference" => reference, "title" => title, "description" => "Inmueble ficticio",
      "address" => "Calle Falsa 123", "city" => "Madrid", "region" => "Madrid", "property_type" => "apartment",
      "deal_type" => deal_type, "price" => price, "currency" => "EUR", "bedrooms" => 3, "bathrooms" => 2,
      "area_sqft" => "1076.39", "latitude" => 40.4, "longitude" => -3.7, "views_count" => 7,
      "gallery" => gallery || [
        { "url" => "https://liberu.test/storage/a.png", "kind" => "photograph", "caption" => "Salón" },
        { "url" => "https://liberu.test/storage/b.png", "kind" => "photograph", "caption" => nil }
      ]
    }
  end

  def run(items, **opts)
    client = instance_double(Pwb::LiberuSync::Client, fetch_all: items)
    described_class.new(website: website, client: client, photo_fetcher: fake_fetcher, **opts).call
  end

  def asset(reference = "RE-2026-00042")
    Pwb::RealtyAsset.find_by(website_id: website.id, reference: reference)
  end

  it "creates the asset, a visible sale listing and its photos" do
    result = run([item])

    expect(result.created).to eq(["RE-2026-00042"])
    expect(result.errors).to be_empty
    expect(asset.sale_listings.find_by(active: true)).to have_attributes(visible: true, price_sale_current_cents: 25_000_000)
    expect(asset.constructed_area).to be_within(0.01).of(100.0)
    expect(asset.prop_photos.order(:sort_order).pluck(:description)).to eq(["Salón", nil])
  end

  it "is idempotent: a retry with the same data creates nothing and downloads nothing" do
    run([item])
    calls_after_first_run = fake_fetcher.calls.size

    expect { run([item]) }.not_to change { [Pwb::RealtyAsset.count, Pwb::PropPhoto.count, Pwb::SaleListing.count] }
    expect(fake_fetcher.calls.size).to eq(calls_after_first_run)
    expect(Pwb::ExternalSyncRecord.where(external_reference: "RE-2026-00042").count).to eq(1)
  end

  it "adopts a pre-existing asset with the same reference instead of duplicating it" do
    existing = Pwb::RealtyAsset.create!(website: website, reference: "RE-2026-00042", title: "old")

    expect { run([item]) }.not_to change(Pwb::RealtyAsset, :count)
    expect(Pwb::ExternalSyncRecord.find_by(external_reference: "RE-2026-00042").realty_asset_id).to eq(existing.id)
  end

  it "updates the price in place" do
    run([item])
    result = run([item(price: "239000.00")])

    expect(result.updated).to eq(["RE-2026-00042"])
    expect(asset.sale_listings.find_by(active: true).price_sale_current_cents).to eq(23_900_000)
    expect(Pwb::SaleListing.where(realty_asset_id: asset.id).count).to eq(1)
  end

  it "adds, reorders and removes only the photos it owns" do
    run([item])
    manual = Pwb::PropPhoto.create!(realty_asset: asset, sort_order: 99)

    gallery = [
      { "url" => "https://liberu.test/storage/c.png", "kind" => "photograph", "caption" => "Cocina" },
      { "url" => "https://liberu.test/storage/a.png", "kind" => "photograph", "caption" => "Salón" }
    ]
    result = run([item(gallery: gallery)])

    expect(result.photos_added).to eq(1)
    expect(result.photos_removed).to eq(1)
    expect(asset.prop_photos.where.not(id: manual.id).order(:sort_order).pluck(:description)).to eq(%w[Cocina Salón])
    expect(Pwb::PropPhoto.exists?(manual.id)).to be true
  end

  it "withdraws a property that left Liberu's public set and republishes it when it returns" do
    run([item, item(reference: "RE-2026-00043")])

    result = run([item(reference: "RE-2026-00043")])
    expect(result.withdrawn).to eq(["RE-2026-00042"])
    expect(asset.sale_listings.where(visible: true)).to be_empty

    result = run([item, item(reference: "RE-2026-00043")])
    expect(result.republished).to eq(["RE-2026-00042"])
    expect(asset.sale_listings.find_by(active: true).visible).to be true
  end

  it "never unpublishes everything when Liberu returns an empty listing" do
    run([item])
    result = run([])

    expect(result.skipped_withdrawals).to be true
    expect(asset.sale_listings.find_by(active: true).visible).to be true
  end

  it "unpublishes on an empty listing only when explicitly allowed" do
    run([item])
    result = run([], allow_empty: true)

    expect(result.withdrawn).to eq(["RE-2026-00042"])
  end

  it "does not write anything when the Liberu listing cannot be fetched" do
    run([item])
    client = instance_double(Pwb::LiberuSync::Client)
    allow(client).to receive(:fetch_all).and_raise(Pwb::LiberuSync::FetchError, "boom")

    expect { described_class.new(website: website, client: client, photo_fetcher: fake_fetcher).call }
      .to raise_error(Pwb::LiberuSync::FetchError)
    expect(asset.sale_listings.find_by(active: true).visible).to be true
  end

  it "moves a property from sale to rent without leaving the sale listing visible" do
    run([item])
    run([item(deal_type: "rent", price: "1200.00")])

    expect(asset.sale_listings.where(visible: true)).to be_empty
    expect(asset.rental_listings.find_by(active: true)).to have_attributes(visible: true, for_rent_long_term: true,
                                                                          price_rental_monthly_current_cents: 120_000)
  end
end
