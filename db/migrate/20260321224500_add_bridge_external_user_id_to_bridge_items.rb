class AddBridgeExternalUserIdToBridgeItems < ActiveRecord::Migration[7.2]
  def change
    add_column :bridge_items, :bridge_external_user_id, :string
  end
end
