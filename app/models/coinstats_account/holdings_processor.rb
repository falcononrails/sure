# frozen_string_literal: true

class CoinstatsAccount::HoldingsProcessor
  def initialize(coinstats_account)
    @coinstats_account = coinstats_account
  end

  def process
    return unless account&.crypto?
    return if coinstats_account.fiat_asset?

    quantity = coinstats_account.asset_quantity
    return if quantity.zero?

    security = resolve_security
    return unless security

    price = coinstats_account.asset_price
    amount = coinstats_account.inferred_current_balance

    import_adapter.import_holding(
      security: security,
      quantity: quantity.abs,
      amount: amount,
      currency: account.currency,
      date: Date.current,
      price: price,
      cost_basis: coinstats_account.average_buy_price,
      external_id: external_id,
      account_provider_id: coinstats_account.account_provider&.id,
      source: "coinstats",
      delete_future_holdings: false
    )
  end

  private
    attr_reader :coinstats_account

    def account
      coinstats_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def external_id
      "coinstats_holding_#{coinstats_account.account_id}_#{Date.current}"
    end

    def resolve_security
      symbol = coinstats_account.asset_symbol
      return if symbol.blank?

      ticker = symbol.start_with?("CRYPTO:") ? symbol : "CRYPTO:#{symbol}"
      security = Security::Resolver.new(ticker).resolve
      return unless security

      updates = {}
      updates[:name] = coinstats_account.asset_name if security.name.blank? && coinstats_account.asset_name.present?
      updates[:offline] = true if security.respond_to?(:offline=) && security.offline != true
      security.update!(updates) if updates.any?
      security
    rescue => e
      Rails.logger.warn("CoinstatsAccount::HoldingsProcessor - Failed to resolve #{symbol}: #{e.class} - #{e.message}")
      nil
    end
end
