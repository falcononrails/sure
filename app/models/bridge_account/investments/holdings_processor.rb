class BridgeAccount::Investments::HoldingsProcessor
  def initialize(bridge_account)
    @bridge_account = bridge_account
  end

  def process
    return if account.blank?
    return unless account.investment?
    return if account_provider.blank?

    cleanup_stale_holdings!(active_external_ids)

    active_stocks.each do |stock_snapshot|
      import_holding(stock_snapshot)
    end
  end

  private
    attr_reader :bridge_account

    def account
      bridge_account.current_account
    end

    def account_provider
      bridge_account.account_provider
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def active_stocks
      @active_stocks ||= bridge_account.active_stocks_snapshot.map do |stock_snapshot|
        stock_snapshot.with_indifferent_access
      end
    end

    def active_external_ids
      active_stocks.map { |stock_snapshot| external_id_for(stock_snapshot) }
    end

    def cleanup_stale_holdings!(external_ids)
      scope = account.holdings.where(
        account_provider_id: account_provider.id,
        date: holding_date
      )

      if external_ids.any?
        scope.where.not(external_id: external_ids).delete_all
      else
        scope.delete_all
      end
    end

    def import_holding(stock_snapshot)
      quantity = parse_decimal(stock_snapshot[:quantity])
      total_value = parse_decimal(stock_snapshot[:total_value])
      price = parse_decimal(stock_snapshot[:current_price])
      average_purchase_price = parse_decimal(stock_snapshot[:average_purchase_price])

      return if quantity.nil? || quantity.zero?
      price ||= total_value / quantity if total_value.present? && quantity.nonzero?
      amount = total_value || (price * quantity if price.present?)
      return if amount.nil?

      security = resolve_security!(stock_snapshot)

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: stock_snapshot[:currency_code].presence || account.currency,
        date: holding_date,
        price: price,
        cost_basis: average_purchase_price,
        external_id: external_id_for(stock_snapshot),
        account_provider_id: account_provider.id,
        source: "bridge",
        delete_future_holdings: false
      )
    end

    def resolve_security!(stock_snapshot)
      ticker = stock_snapshot[:isin].to_s.strip.upcase
      label = stock_snapshot[:label].to_s.strip

      if ticker.blank?
        ticker = "BRIDGE:#{(stock_snapshot[:stock_key] || stock_snapshot[:id]).to_s.strip.upcase}"
      end

      security = Security.find_or_initialize_by(ticker: ticker)
      security.name = label if label.present? && (security.name.blank? || security.name == security.ticker)

      if ticker.start_with?("BRIDGE:")
        security.offline = true if security.respond_to?(:offline)
      end

      security.save! if security.new_record? || security.changed?
      security
    rescue ActiveRecord::RecordNotUnique
      Security.find_by!(ticker: ticker)
    end

    def external_id_for(stock_snapshot)
      stock_identifier = stock_snapshot[:stock_key].presence || stock_snapshot[:id].presence || stock_snapshot[:isin].presence
      "bridge_stock_#{stock_identifier}"
    end

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when Numeric
        BigDecimal(value.to_s)
      when String
        BigDecimal(value)
      else
        nil
      end
    rescue ArgumentError
      nil
    end

    def holding_date
      Date.current
    end
end
