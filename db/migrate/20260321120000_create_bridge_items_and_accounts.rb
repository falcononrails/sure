class CreateBridgeItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :bridge_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color
      t.string :status, default: "pending_connect"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false
      t.datetime :sync_start_date
      t.datetime :transactions_synced_at
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload
      t.string :bridge_item_id
      t.integer :bridge_status
      t.string :status_code_info
      t.text :status_code_description
      t.datetime :authentication_expires_at

      t.timestamps
    end

    add_index :bridge_items, :status
    add_index :bridge_items, :bridge_item_id, unique: true, where: "bridge_item_id IS NOT NULL"

    create_table :bridge_accounts, id: :uuid do |t|
      t.references :bridge_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :bridge_account_id
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :account_subtype
      t.string :account_category
      t.string :data_access
      t.string :provider_id
      t.string :iban
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :bridge_accounts, [ :bridge_item_id, :bridge_account_id ],
              unique: true,
              where: "bridge_account_id IS NOT NULL",
              name: "index_bridge_accounts_on_item_and_bridge_account_id"
  end
end
