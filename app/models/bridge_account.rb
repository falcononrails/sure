class BridgeAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
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

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Bridge account #{id}, defaulting to EUR")
    end
end
