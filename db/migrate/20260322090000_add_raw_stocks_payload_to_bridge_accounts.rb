class AddRawStocksPayloadToBridgeAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :bridge_accounts, :raw_stocks_payload, :jsonb
  end
end
