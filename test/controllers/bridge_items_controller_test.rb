require "test_helper"

class BridgeItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "new creates pending bridge item and renders redirect view" do
    provider = mock
    Provider::Registry.expects(:get_provider).with(:bridge).returns(provider)
    provider.expects(:ensure_user_token!).with(external_user_id: "sure-family-#{@user.family_id}", user_email: @user.email).returns("bridge_token")
    provider.expects(:create_connect_session).returns(url: "https://connect.bridgeapi.io/session/123")

    assert_difference "BridgeItem.count", 1 do
      get new_bridge_item_url
    end

    assert_response :success
    assert_select "[data-controller='bridge-connect']"
    assert_equal "pending_connect", BridgeItem.order(:created_at).last.status
  end

  test "callback finalizes bridge item and schedules sync" do
    bridge_item = @user.family.bridge_items.create!(name: "Bridge connection")
    BridgeItem.any_instance.expects(:sync_later).once

    get callback_bridge_items_url, params: {
      context: bridge_item.connect_context,
      item_id: "item_987",
      success: "true"
    }

    assert_redirected_to accounts_path
    assert_equal "Bridge connection started. Your accounts are syncing.", flash[:notice]
    assert_equal "item_987", bridge_item.reload.bridge_item_id
    assert_equal "good", bridge_item.status
  end

  test "callback removes pending item on cancellation" do
    bridge_item = @user.family.bridge_items.create!(name: "Bridge connection")

    assert_difference "BridgeItem.count", -1 do
      get callback_bridge_items_url, params: {
        context: bridge_item.connect_context,
        success: "false"
      }
    end

    assert_redirected_to accounts_path
    assert_equal "Bridge connection was not completed.", flash[:alert]
  end

  test "sync enqueues sync for bridge item" do
    bridge_item = bridge_items(:one)
    BridgeItem.any_instance.expects(:sync_later).once

    post sync_bridge_item_url(bridge_item)

    assert_redirected_to accounts_path
  end

  test "link_existing_account links bridge account to existing account" do
    account = accounts(:depository)
    bridge_account = BridgeAccount.create!(
      bridge_item: bridge_items(:one),
      name: "Linkable Bridge Account",
      bridge_account_id: "acc_linkable",
      currency: "USD",
      current_balance: 100,
      account_type: "checking",
      data_access: "enabled",
      raw_payload: {}
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_bridge_items_url, params: {
        account_id: account.id,
        bridge_account_id: bridge_account.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal "Account successfully linked to Bridge.", flash[:notice]
  end
end
