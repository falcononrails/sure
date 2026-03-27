# Represents a single crypto token/coin within a CoinStats wallet.
# Each wallet address may have multiple CoinstatsAccounts (one per token).
class CoinstatsAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :coinstats_item

  # Association through account_providers (standard pattern for all providers)
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: [ :coinstats_item_id, :wallet_address ], allow_nil: true }

  # Alias for compatibility with provider adapter pattern
  alias_method :current_account, :account

  # Updates account with latest balance data from CoinStats API.
  # @param account_snapshot [Hash] Normalized balance data from API
  def upsert_coinstats_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Build attributes to update
    attrs = {
      current_balance: snapshot[:balance] || snapshot[:current_balance] || inferred_current_balance(snapshot),
      currency: inferred_currency(snapshot) || parse_currency(snapshot[:currency]) || "USD",
      name: snapshot[:name],
      account_status: snapshot[:status],
      provider: snapshot[:provider],
      institution_metadata: {
        logo: snapshot[:institution_logo]
      }.compact,
      raw_payload: account_snapshot
    }

    # Only set account_id if provided and not already set (preserves ID from initial creation)
    if snapshot[:id].present? && account_id.blank?
      attrs[:account_id] = snapshot[:id].to_s
    end

    update!(attrs)
  end

  # Stores transaction data from CoinStats API for later processing.
  # @param transactions_snapshot [Hash, Array] Raw transactions response or array
  def upsert_coinstats_transactions_snapshot!(transactions_snapshot)
    # CoinStats API returns: { meta: { page, limit }, result: [...] }
    # Extract just the result array for storage, or use directly if already an array
    transactions_array = if transactions_snapshot.is_a?(Hash)
      snapshot = transactions_snapshot.with_indifferent_access
      snapshot[:result] || []
    elsif transactions_snapshot.is_a?(Array)
      transactions_snapshot
    else
      []
    end

    assign_attributes(
      raw_transactions_payload: transactions_array
    )

    save!
  end

  def wallet_source?
    payload = raw_payload.to_h.with_indifferent_access
    payload[:address].present? && payload[:blockchain].present?
  end

  def exchange_source?
    raw_payload.to_h.with_indifferent_access[:portfolio_id].present?
  end

  def fiat_asset?(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access
    metadata = asset_metadata(payload)

    metadata[:isFiat] == true ||
      payload[:isFiat] == true ||
      parse_currency(metadata[:symbol]).present?
  end

  def crypto_asset?
    !fiat_asset?
  end

  def inferred_currency(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access

    if fiat_asset?(payload)
      parse_currency(asset_metadata(payload)[:symbol]) || parse_currency(payload[:currency]) || "USD"
    else
      parse_currency(payload[:currency]) || "USD"
    end
  end

  def inferred_current_balance(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access

    if fiat_asset?(payload)
      asset_quantity(payload).abs
    else
      explicit_balance = payload[:balance] || payload[:current_balance]
      return parse_decimal(explicit_balance) if explicit_balance.present?

      asset_quantity(payload).abs * asset_price(payload)
    end
  end

  def inferred_cash_balance
    fiat_asset? ? inferred_current_balance : 0.to_d
  end

  def asset_symbol(payload = raw_payload)
    asset_metadata(payload)[:symbol].presence || account_id.to_s.upcase
  end

  def asset_name(payload = raw_payload)
    asset_metadata(payload)[:name].presence || name
  end

  def asset_quantity(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access
    raw_quantity = payload[:count] || payload[:amount] || payload[:balance] || payload[:current_balance]
    parse_decimal(raw_quantity)
  end

  def asset_price(payload = raw_payload, currency: inferred_currency(payload))
    payload = payload.to_h.with_indifferent_access
    price_data = payload[:price]

    raw_price =
      if price_data.is_a?(Hash)
        price_data.with_indifferent_access[currency] || price_data.with_indifferent_access[:USD]
      else
        price_data || payload[:priceUsd]
      end

    parse_decimal(raw_price)
  end

  def average_buy_price(payload = raw_payload, currency: inferred_currency(payload))
    payload = payload.to_h.with_indifferent_access
    average_buy = payload[:averageBuy].to_h.with_indifferent_access
    all_time = average_buy[:allTime].to_h.with_indifferent_access

    raw_cost_basis = all_time[currency] || all_time[:USD]
    return nil if raw_cost_basis.blank?

    parse_decimal(raw_cost_basis)
  end

  private
    def asset_metadata(payload)
      payload = payload.to_h.with_indifferent_access
      metadata = payload[:coin]
      metadata.is_a?(Hash) ? metadata.with_indifferent_access : payload
    end

    def parse_decimal(value)
      return 0.to_d if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      0.to_d
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for CoinstatsAccount #{id}, defaulting to USD")
    end
end
