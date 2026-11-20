# frozen_string_literal: true

# Tracks properties that PWB mirrors from an external source of truth
# (CLARTO staging: Liberu Real Estate). One row per (website, source, reference);
# the unique index is what makes a retried or concurrent sync unable to create
# a second RealtyAsset for the same external reference.
class CreatePwbExternalSyncRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :pwb_external_sync_records do |t|
      t.bigint :website_id, null: false
      t.string :source, null: false
      t.string :external_reference, null: false
      t.uuid :realty_asset_id
      t.string :state, null: false, default: "published"
      t.string :payload_digest
      t.string :photos_digest
      t.jsonb :photo_map, null: false, default: []
      t.datetime :last_seen_at
      t.datetime :withdrawn_at
      t.timestamps
    end

    add_index :pwb_external_sync_records, %i[website_id source external_reference],
              unique: true, name: "index_pwb_external_sync_records_unique_ref"
    add_index :pwb_external_sync_records, :realty_asset_id
    add_foreign_key :pwb_external_sync_records, :pwb_websites, column: :website_id
    add_foreign_key :pwb_external_sync_records, :pwb_realty_assets, column: :realty_asset_id, on_delete: :nullify
  end
end
