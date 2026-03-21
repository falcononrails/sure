require "test_helper"

class BridgeItem::ImporterTest < ActiveSupport::TestCase
  test "imports accounts and only stores transactions for accounts with data access" do
    bridge_item = BridgeItem.create!(
      family: families(:dylan_family),
      name: "Bridge Demo",
      status: :good,
      bridge_item_id: "item_importer"
    )

    provider = mock
    provider.expects(:ensure_user_token!).with(external_user_id: "sure-family-#{bridge_item.family_id}").returns("bridge_token")
    provider.expects(:get_item).with(user_token: "bridge_token", item_id: "item_importer").returns({ status: 0, provider_id: 120 })
    provider.expects(:get_provider).with(provider_id: 120).returns({ id: 120, name: "Bridge Demo Bank" })
    provider.expects(:list_accounts).with(user_token: "bridge_token").returns(
      [
        { id: "acc_enabled", item_id: "item_importer", name: "Enabled Account", balance: "100.00", currency_code: "EUR", type: "checking", data_access: "enabled" },
        { id: "acc_disabled", item_id: "item_importer", name: "Disabled Account", balance: "50.00", currency_code: "EUR", type: "checking", data_access: "disabled" }
      ]
    )
    provider.expects(:list_transactions).with(user_token: "bridge_token", since: nil).returns(
      [
        { id: "tx_enabled", account_id: "acc_enabled", amount: "-10.00", currency_code: "EUR", booking_date: "2026-03-20", clean_description: "Groceries" },
        { id: "tx_disabled", account_id: "acc_disabled", amount: "-5.00", currency_code: "EUR", booking_date: "2026-03-20", clean_description: "Ignored" }
      ]
    )

    result = BridgeItem::Importer.new(bridge_item, bridge_provider: provider).import

    assert_equal true, result[:success]
    assert_equal 2, bridge_item.bridge_accounts.count
    assert_equal 1, bridge_item.bridge_accounts.active_data_access.count
    assert_equal [ "tx_enabled" ], bridge_item.bridge_accounts.find_by(bridge_account_id: "acc_enabled").raw_transactions_payload.map { |tx| tx["id"] || tx[:id] }
    assert_equal [], bridge_item.bridge_accounts.find_by(bridge_account_id: "acc_disabled").raw_transactions_payload.to_a
  end
end
