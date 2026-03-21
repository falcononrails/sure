require "test_helper"

class Provider::BridgeTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Bridge.new(client_id: "client_id", client_secret: "client_secret")
  end

  test "ensure_user_token creates missing user then retries" do
    sequence = sequence("bridge-auth")

    Provider::Bridge.expects(:post).with do |url, options|
      url == "#{Provider::Bridge::BASE_URL}/authorization/token" &&
        options[:body] == { external_user_id: "sure-family-1" }.to_json
    end.in_sequence(sequence).returns(response(code: 404, body: { message: "not found" }))

    Provider::Bridge.expects(:post).with do |url, options|
      url == "#{Provider::Bridge::BASE_URL}/users" &&
        options[:body] == { external_user_id: "sure-family-1" }.to_json
    end.in_sequence(sequence).returns(response(code: 201, body: { id: "user_1" }))

    Provider::Bridge.expects(:post).with do |url, options|
      url == "#{Provider::Bridge::BASE_URL}/authorization/token" &&
        options[:body] == { external_user_id: "sure-family-1" }.to_json
    end.in_sequence(sequence).returns(response(code: 200, body: { access_token: "bridge_token" }))

    assert_equal "bridge_token", @provider.ensure_user_token!(external_user_id: "sure-family-1")
  end

  test "create_connect_session sends expected request body" do
    Provider::Bridge.expects(:post).with do |url, options|
      parsed_body = JSON.parse(options[:body])

      url == "#{Provider::Bridge::BASE_URL}/connect-sessions" &&
        parsed_body == {
          "user_email" => "bob@bobdylan.com",
          "callback_url" => "https://example.com/bridge/callback",
          "account_types" => "all",
          "context" => "signed_context",
          "item_id" => "item_123"
        } &&
        options[:headers]["Authorization"] == "Bearer user_token"
    end.returns(response(code: 201, body: { url: "https://connect.bridgeapi.io/session/123" }))

    result = @provider.create_connect_session(
      user_token: "user_token",
      user_email: "bob@bobdylan.com",
      callback_url: "https://example.com/bridge/callback",
      account_types: "all",
      item_id: "item_123",
      context: "signed_context"
    )

    assert_equal "https://connect.bridgeapi.io/session/123", result[:url]
  end

  test "list_transactions follows pagination" do
    since = Time.zone.parse("2026-03-21T10:15:00Z")
    sequence = sequence("bridge-pagination")

    Provider::Bridge.expects(:get).with do |url, options|
      url == "#{Provider::Bridge::BASE_URL}/transactions" &&
        options[:query] == { since: since.iso8601 }
    end.in_sequence(sequence).returns(
      response(
        code: 200,
        body: {
          transactions: [ { id: "tx_1" } ],
          pagination: { next_uri: "/transactions?starting_after=tx_1" }
        }
      )
    )

    Provider::Bridge.expects(:get).with do |url, options|
      url == "#{Provider::Bridge::BASE_URL}/transactions?starting_after=tx_1" &&
        options[:query].nil?
    end.in_sequence(sequence).returns(
      response(
        code: 200,
        body: {
          transactions: [ { id: "tx_2" } ],
          pagination: {}
        }
      )
    )

    transactions = @provider.list_transactions(user_token: "user_token", since: since)

    assert_equal %w[tx_1 tx_2], transactions.map { |transaction| transaction[:id] }
  end

  private
    def response(code:, body:, message: "OK")
      Struct.new(:code, :body, :message).new(code, body.to_json, message)
    end
end
