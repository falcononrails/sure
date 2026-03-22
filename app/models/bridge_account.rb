class BridgeAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    encrypts :raw_stocks_payload
  end

  belongs_to :bridge_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :bridge_account_id, uniqueness: { scope: :bridge_item_id, allow_nil: true }
  validates :name, :currency, presence: true

  scope :active_data_access, -> { where("data_access IS NULL OR data_access != ?", "disabled") }

  def current_account
    account
  end

  def upsert_bridge_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    assign_attributes(
      name: build_name(snapshot),
      bridge_account_id: snapshot[:id]&.to_s,
      current_balance: parse_balance(snapshot[:balance]),
      available_balance: parse_balance(snapshot[:available_balance]),
      currency: parse_currency(snapshot[:currency_code] || snapshot[:currency]) || "EUR",
      account_status: snapshot[:status]&.to_s,
      account_type: snapshot[:type]&.to_s,
      account_subtype: snapshot[:subtype]&.to_s,
      account_category: snapshot[:category]&.to_s,
      data_access: snapshot[:data_access]&.to_s,
      provider_id: snapshot[:provider_id]&.to_s,
      iban: snapshot[:iban] || snapshot.dig(:identifiers, :iban),
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_bridge_transactions_snapshot!(transactions_snapshot)
    existing_transactions = raw_transactions_payload.to_a
    merged = existing_transactions.index_by do |transaction|
      transaction.with_indifferent_access[:id].to_s
    end

    Array(transactions_snapshot).each do |transaction|
      merged[transaction.with_indifferent_access[:id].to_s] = transaction
    end

    update!(raw_transactions_payload: merged.values)
  end

  def upsert_bridge_stocks_snapshot!(stocks_snapshot)
    update!(raw_stocks_payload: normalize_stocks_snapshot(stocks_snapshot))
  end

  def active_stocks_snapshot
    normalize_stocks_snapshot(raw_stocks_payload).filter_map do |stock_snapshot|
      stock = stock_snapshot.with_indifferent_access
      next if ActiveModel::Type::Boolean.new.cast(stock[:deleted])

      stock_snapshot
    end
  end

  def current_holdings_value
    active_stocks_snapshot.sum(0.to_d) do |stock_snapshot|
      stock = stock_snapshot.with_indifferent_access
      total_value = parse_balance(stock[:total_value])
      next total_value if total_value.present?

      quantity = parse_balance(stock[:quantity]) || 0
      price = parse_balance(stock[:current_price]) || 0
      quantity * price
    end
  end

  def effective_total_balance
    return current_balance unless investment_account?

    holdings_value = current_holdings_value
    return holdings_value if current_balance.blank?
    return current_balance if holdings_value.zero?

    [ current_balance, holdings_value ].max
  end

  def effective_cash_balance
    return current_balance unless investment_account?

    total_balance = effective_total_balance
    return nil if total_balance.blank?

    [ total_balance - current_holdings_value, 0.to_d ].max
  end

  def investment_account?
    current_account&.investment?
  end

  private
    def build_name(snapshot)
      snapshot[:name].presence || begin
        iban = snapshot[:iban] || snapshot.dig(:identifiers, :iban)
        iban.present? ? "Account ...#{iban.to_s.last(4)}" : "Bridge Account"
      end
    end

    def parse_balance(value)
      return if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def normalize_stocks_snapshot(stocks_snapshot)
      Array(stocks_snapshot).each_with_object({}) do |stock_snapshot, grouped|
        stock = stock_snapshot.with_indifferent_access
        dedupe_key = stock[:isin].presence || stock[:stock_key].presence || stock[:id].to_s
        next if dedupe_key.blank?

        existing = grouped[dedupe_key]
        grouped[dedupe_key] = preferred_stock_snapshot(existing, stock_snapshot)
      end.values
    end

    def preferred_stock_snapshot(existing_snapshot, candidate_snapshot)
      return candidate_snapshot if existing_snapshot.blank?

      existing = existing_snapshot.with_indifferent_access
      candidate = candidate_snapshot.with_indifferent_access

      existing_deleted = ActiveModel::Type::Boolean.new.cast(existing[:deleted])
      candidate_deleted = ActiveModel::Type::Boolean.new.cast(candidate[:deleted])

      return candidate_snapshot if existing_deleted && !candidate_deleted
      return existing_snapshot if candidate_deleted && !existing_deleted

      existing_id = existing[:id].to_i
      candidate_id = candidate[:id].to_i

      candidate_id >= existing_id ? candidate_snapshot : existing_snapshot
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Bridge account #{id}, defaulting to EUR")
    end
end
