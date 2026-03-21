class BridgeAccount::Processor
  include BridgeAccount::TypeMappable

  attr_reader :bridge_account

  def initialize(bridge_account)
    @bridge_account = bridge_account
  end

  def process
    auto_link_account! if bridge_account.current_account.blank?
    return { processed: false, skipped_entries: [] } if bridge_account.current_account.blank?

    process_account!
    process_holdings!
    transaction_result = BridgeAccount::Transactions::Processor.new(bridge_account).process

    {
      processed: true,
      skipped_entries: transaction_result[:skipped_entries].to_a
    }
  end

  private
    def auto_link_account!
      mapping = auto_mapping
      return unless mapping
      return if bridge_account.account_provider.present?

      account = Account.create_and_sync(
        {
          family: bridge_account.bridge_item.family,
          name: bridge_account.name,
          balance: bridge_account.current_balance || 0,
          cash_balance: bridge_account.current_balance || 0,
          currency: bridge_account.currency || "EUR",
          accountable_type: mapping[:accountable_type],
          accountable_attributes: mapping[:subtype].present? ? { subtype: mapping[:subtype] } : {}
        },
        skip_initial_sync: true
      )

      AccountProvider.create!(account: account, provider: bridge_account)
    end

    def process_account!
      account = bridge_account.current_account

      account.enrich_attributes(
        { name: bridge_account.name },
        source: "bridge"
      )

      total_balance = bridge_account.effective_total_balance
      cash_balance = bridge_account.effective_cash_balance

      if total_balance.present?
        account.update!(
          balance: total_balance,
          cash_balance: cash_balance || total_balance,
          currency: bridge_account.currency
        )
        account.set_current_balance(total_balance)
      elsif bridge_account.currency.present?
        account.update!(currency: bridge_account.currency)
      end
    end

    def process_holdings!
      return unless bridge_account.current_account&.investment?

      BridgeAccount::Investments::HoldingsProcessor.new(bridge_account).process
    end
end
