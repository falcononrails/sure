class Provider::BridgeAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  Provider::Factory.register("BridgeAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_bridge?

    [ {
      key: "bridge",
      name: "Bridge",
      description: "Connect to your bank via Bridge",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_bridge_item_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_bridge_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  configure do
    description <<~DESC
      Setup instructions:
      1. Visit the [Bridge dashboard](https://dashboard.bridgeapi.io/) to get your application credentials
      2. Configure a service account with aggregation permissions
      3. Add your local callback URL to the Bridge application settings
    DESC

    field :client_id,
          label: "Client ID",
          required: false,
          env_key: "BRIDGE_CLIENT_ID",
          description: "Your Bridge application client ID"

    field :client_secret,
          label: "Client Secret",
          required: false,
          secret: true,
          env_key: "BRIDGE_CLIENT_SECRET",
          description: "Your Bridge application client secret"

    configured_check { get_value(:client_id).present? && get_value(:client_secret).present? }
  end

  def provider_name
    "bridge"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_bridge_item_path(item)
  end

  def item
    provider_account.bridge_item
  end

  def institution_domain
    item&.institution_domain
  end

  def institution_name
    item&.institution_display_name
  end

  def institution_url
    item&.institution_url
  end

  def institution_color
    item&.institution_color
  end

  def logo_url
    item&.raw_institution_payload&.dig("images", "logo")
  end
end
