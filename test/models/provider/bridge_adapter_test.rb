require "test_helper"

class Provider::BridgeAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @bridge_account = bridge_accounts(:one)
    @account = accounts(:depository)
    @adapter = Provider::BridgeAdapter.new(@bridge_account, account: @account)
  end

  def adapter
    @adapter
  end

  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  test "returns correct provider name" do
    assert_equal "bridge", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "BridgeAccount", @adapter.provider_type
  end

  test "returns bridge item" do
    assert_equal @bridge_account.bridge_item, @adapter.item
  end

  test "returns logo url from institution payload" do
    @bridge_account.bridge_item.update!(raw_institution_payload: { "images" => { "logo" => "https://example.com/logo.png" } })

    assert_equal "https://example.com/logo.png", @adapter.logo_url
  end
end
