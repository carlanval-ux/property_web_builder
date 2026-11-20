# frozen_string_literal: true

module Pwb
  # One row per property PWB mirrors from an external source of truth.
  # See Pwb::LiberuSync::Importer.
  class ExternalSyncRecord < ApplicationRecord
    self.table_name = "pwb_external_sync_records"

    STATES = %w[published withdrawn].freeze

    belongs_to :website, class_name: "Pwb::Website"
    belongs_to :realty_asset, class_name: "Pwb::RealtyAsset", optional: true

    validates :source, :external_reference, presence: true
    validates :state, inclusion: { in: STATES }
    validates :external_reference, uniqueness: { scope: %i[website_id source] }

    scope :for_source, ->(source) { where(source: source) }
    scope :published, -> { where(state: "published") }
  end
end
