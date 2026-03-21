require "test_helper"

class BridgeEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @bridge_item = BridgeItem.create!(
      family: @account.family,
      name: "Bridge Demo Bank",
      status: :good,
      bridge_item_id: "item_processor"
    )
    @bridge_account = BridgeAccount.create!(
      bridge_item: @bridge_item,
      name: "Processor Checking",
      bridge_account_id: "acc_processor",
      currency: "USD",
      current_balance: 1000,
      account_type: "checking",
      data_access: "enabled",
      raw_payload: {}
    )
    AccountProvider.create!(account: @account, provider: @bridge_account)
  end

  test "imports transaction with inverted amount sign and bridge metadata" do
    BridgeEntry::Processor.new(
      {
        id: "txn_1",
        account_id: "acc_processor",
        amount: "-12.34",
        currency_code: "USD",
        booking_date: "2026-03-20",
        clean_description: "Coffee Shop",
        provider_description: "COFFEE SHOP 123",
        future: false,
        deleted: false,
        operation_type: "card"
      },
      bridge_account: @bridge_account
    ).process

    entry = @account.entries.find_by(source: "bridge", external_id: "txn_1")

    assert_not_nil entry
    assert_equal BigDecimal("12.34"), entry.amount
    assert_equal "Coffee Shop", entry.name
    assert_equal "COFFEE SHOP 123", entry.entryable.extra.dig("bridge", "provider_description")
  end

  test "skips future transactions" do
    result = BridgeEntry::Processor.new(
      {
        id: "txn_future",
        account_id: "acc_processor",
        amount: "-50",
        currency_code: "USD",
        booking_date: "2026-03-20",
        clean_description: "Pending Card",
        future: true
      },
      bridge_account: @bridge_account
    ).process

    assert_nil result
    assert_nil @account.entries.find_by(source: "bridge", external_id: "txn_future")
  end
end
