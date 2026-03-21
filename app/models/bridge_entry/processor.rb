class BridgeEntry::Processor
  include CurrencyNormalizable

  def initialize(bridge_transaction, bridge_account:, import_adapter: nil)
    @bridge_transaction = bridge_transaction
    @bridge_account = bridge_account
    @shared_import_adapter = import_adapter
  end

  def process
    return nil if future_transaction?

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "bridge",
      notes: notes,
      extra: extra_metadata
    )
  end

  private
    attr_reader :bridge_transaction, :bridge_account

    def import_adapter
      @import_adapter ||= @shared_import_adapter || Account::ProviderImportAdapter.new(account)
    end

    def account
      bridge_account.current_account
    end

    def data
      @data ||= bridge_transaction.with_indifferent_access
    end

    def future_transaction?
      ActiveModel::Type::Boolean.new.cast(data[:future])
    end

    def external_id
      id = data[:id].presence
      raise ArgumentError, "Bridge transaction missing id" if id.blank?

      id.to_s
    end

    def name
      data[:clean_description].presence || data[:provider_description].presence || I18n.t("transactions.unknown_name")
    end

    def amount
      raw_amount = data[:amount] || data.dig(:amounts, :booked)
      raise ArgumentError, "Bridge transaction missing amount" if raw_amount.blank?

      -BigDecimal(raw_amount.to_s)
    end

    def currency
      parse_currency(data[:currency_code] || data[:currency]) || account.currency || "EUR"
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Bridge transaction #{external_id}")
    end

    def date
      date_value = data[:booking_date] || data[:date] || data[:transaction_date] || data[:value_date]
      raise ArgumentError, "Bridge transaction missing date" if date_value.blank?

      Date.parse(date_value.to_s)
    end

    def notes
      return nil if data[:provider_description].blank?
      return nil if data[:provider_description] == name

      data[:provider_description]
    end

    def extra_metadata
      {
        "bridge" => {
          "provider_description" => data[:provider_description],
          "operation_type" => data[:operation_type],
          "future" => ActiveModel::Type::Boolean.new.cast(data[:future]),
          "deleted" => ActiveModel::Type::Boolean.new.cast(data[:deleted]),
          "category_id" => data[:category_id],
          "account_id" => data[:account_id]&.to_s,
          "booking_date" => data[:booking_date],
          "transaction_date" => data[:transaction_date],
          "value_date" => data[:value_date]
        }.compact
      }
    end
end
