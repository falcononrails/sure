class Provider::Bridge
  include HTTParty

  BASE_URL = "https://api.bridgeapi.io/v3/aggregation".freeze
  PROVIDERS_URL = "https://api.bridgeapi.io/v3/providers".freeze
  API_VERSION = "2025-01-15".freeze

  headers "User-Agent" => "Sure Finance Bridge Client"
  default_timeout 120

  attr_reader :client_id, :client_secret

  def initialize(client_id:, client_secret:)
    @client_id = client_id
    @client_secret = client_secret
  end

  def ensure_user_access_token!(external_user_id:, user_email: nil)
    create_authorization_token(external_user_id: external_user_id)
  rescue BridgeError => e
    raise unless %i[not_found validation_error].include?(e.error_type)

    create_user(external_user_id: external_user_id, user_email: user_email)
    create_authorization_token(external_user_id: external_user_id)
  end

  def create_connect_session(access_token:, user_email:, callback_url:, account_types: "all", item_id: nil, context: nil)
    body = {
      user_email: user_email,
      callback_url: callback_url,
      account_types: account_types,
      context: context
    }
    body[:item_id] = item_id if item_id.present?

    response = self.class.post(
      "#{BASE_URL}/connect-sessions",
      headers: authenticated_headers(access_token).merge("Content-Type" => "application/json"),
      body: body.to_json
    )

    handle_response(response)
  end

  def get_item(access_token:, item_id:)
    response = self.class.get(
      "#{BASE_URL}/items/#{ERB::Util.url_encode(item_id.to_s)}",
      headers: authenticated_headers(access_token)
    )

    handle_response(response)
  end

  def delete_item(access_token:, item_id:)
    response = self.class.delete(
      "#{BASE_URL}/items/#{ERB::Util.url_encode(item_id.to_s)}",
      headers: authenticated_headers(access_token)
    )

    handle_response(response)
  end

  def list_accounts(access_token:)
    paginated_collection(
      path: "/accounts",
      access_token: access_token,
      collection_keys: %i[accounts resources data results]
    )
  end

  def list_transactions(access_token:, since: nil)
    query = {}
    query[:since] = since.iso8601 if since.respond_to?(:iso8601)

    paginated_collection(
      path: "/transactions",
      access_token: access_token,
      query: query,
      collection_keys: %i[transactions resources data results]
    )
  end

  def get_provider(provider_id:)
    response = self.class.get(
      "#{PROVIDERS_URL}/#{ERB::Util.url_encode(provider_id.to_s)}",
      headers: app_headers
    )

    handle_response(response)
  end

  private
    def create_user(external_user_id:, user_email:)
      response = self.class.post(
        "#{BASE_URL}/users",
        headers: app_headers.merge("Content-Type" => "application/json"),
        body: { external_user_id: external_user_id }.to_json
      )

      handle_response(response)
    rescue BridgeError => e
      raise unless e.error_type == :conflict

      {}
    end

    def create_authorization_token(external_user_id:)
      response = self.class.post(
        "#{BASE_URL}/authorization/token",
        headers: app_headers.merge("Content-Type" => "application/json"),
        body: { external_user_id: external_user_id }.to_json
      )

      parsed = handle_response(response)
      parsed[:access_token] || parsed[:token] || parsed.dig(:data, :access_token)
    end

    def paginated_collection(path:, access_token:, collection_keys:, query: nil)
      items = []
      next_uri = path
      next_query = query.presence

      loop do
        url = build_pagination_url(next_uri)
        response = self.class.get(url, headers: authenticated_headers(access_token), query: next_query)
        parsed = handle_response(response)

        collection = if parsed.is_a?(Array)
          parsed
        else
          collection_keys.lazy.map { |key| parsed[key] }.find(&:present?)
        end
        items.concat(Array(collection))

        next_uri = parsed.is_a?(Hash) ? parsed.dig(:pagination, :next_uri) : nil
        break if next_uri.blank?

        next_query = nil
      end

      items
    end

    def build_pagination_url(next_uri)
      return next_uri if next_uri.start_with?("http")
      return "https://api.bridgeapi.io#{next_uri}" if next_uri.start_with?("/v3/")

      "#{BASE_URL}#{next_uri}"
    end

    def app_headers
      {
        "Client-Id" => client_id,
        "Client-Secret" => client_secret,
        "Bridge-Version" => API_VERSION,
        "Accept" => "application/json"
      }
    end

    def authenticated_headers(access_token)
      app_headers.merge("Authorization" => "Bearer #{access_token}")
    end

    def handle_response(response)
      case response.code
      when 200, 201
        parse_response(response)
      when 204
        {}
      when 400
        raise bridge_error_for(response, :bad_request)
      when 401
        raise bridge_error_for(response, :unauthorized)
      when 403
        raise bridge_error_for(response, :access_forbidden)
      when 404
        raise bridge_error_for(response, :not_found)
      when 409
        raise bridge_error_for(response, :conflict)
      when 422
        raise bridge_error_for(response, :validation_error)
      when 429
        raise bridge_error_for(response, :rate_limited)
      else
        raise bridge_error_for(response, :fetch_failed)
      end
    end

    def parse_response(response)
      return {} if response.body.blank?

      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError => e
      raise BridgeError.new("Failed to parse Bridge response: #{e.message}", :parse_error, response.code)
    end

    def bridge_error_for(response, error_type)
      parsed = JSON.parse(response.body) rescue {}
      message = parsed["message"] || parsed["error"] || parsed["detail"] || parsed["type"] || response.body.presence || "Bridge API request failed"
      BridgeError.new(message, error_type, response.code)
    end

    class BridgeError < StandardError
      attr_reader :error_type, :status_code

      def initialize(message, error_type = :unknown, status_code = nil)
        super(message)
        @error_type = error_type
        @status_code = status_code
      end
    end
end
