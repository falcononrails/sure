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
      isin = stock_snapshot[:isin].to_s.strip.upcase
      label = stock_snapshot[:label].to_s.strip

      if (provider_security = resolve_provider_security(isin: isin, label: label))
        return persist_security(
          ticker: provider_security.ticker,
          exchange_operating_mic: provider_security.exchange_operating_mic,
          country_code: provider_security.country_code,
          name: provider_security.name.presence || label,
          offline: false
        )
      end

      ticker = isin.presence || "BRIDGE:#{(stock_snapshot[:stock_key] || stock_snapshot[:id]).to_s.strip.upcase}"
      offline = ticker.start_with?("BRIDGE:")

      persist_security(
        ticker: ticker,
        name: label,
        offline: offline
      )
    end

    def resolve_provider_security(isin:, label:)
      candidates = []
      candidates = Security.search_provider(isin) if isin.present?
      candidates = Security.search_provider(label) if candidates.empty? && label.present?
      return nil if candidates.empty?

      candidates.find { |candidate| preferred_candidate?(candidate, isin: isin, label: label) } || candidates.first
    rescue => e
      Rails.logger.warn("BridgeAccount::Investments::HoldingsProcessor - Failed to resolve provider security for #{isin.presence || label}: #{e.class} - #{e.message}")
      nil
    end

    def preferred_candidate?(candidate, isin:, label:)
      candidate_ticker = candidate.ticker.to_s.upcase
      candidate_name = candidate.name.to_s.downcase
      label_text = label.to_s.downcase

      return true if isin.present? && candidate_ticker != isin
      return true if label_text.present? && candidate_name.include?(label_text.first(24))

      false
    end

    def persist_security(ticker:, name:, exchange_operating_mic: nil, country_code: nil, offline: false)
      security = Security.find_or_initialize_by(
        ticker: ticker,
        exchange_operating_mic: exchange_operating_mic
      )

      security.name = name if name.present? && (security.name.blank? || security.name == security.ticker)
      security.country_code = country_code if country_code.present?
      security.offline = offline if security.respond_to?(:offline)

      security.save! if security.new_record? || security.changed?
      security
    rescue ActiveRecord::RecordNotUnique
      Security.find_by!(ticker: ticker, exchange_operating_mic: exchange_operating_mic)
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
