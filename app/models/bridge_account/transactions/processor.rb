class BridgeAccount::Transactions::Processor
  attr_reader :bridge_account, :skipped_entries

  def initialize(bridge_account)
    @bridge_account = bridge_account
    @skipped_entries = []
  end

  def process
    transactions = bridge_account.raw_transactions_payload.to_a
    account = bridge_account.current_account

    return { success: true, total: 0, imported: 0, skipped_entries: [] } if transactions.empty? || account.blank?

    adapter = Account::ProviderImportAdapter.new(account)
    imported = 0

    transactions.each do |transaction|
      result = BridgeEntry::Processor.new(
        transaction,
        bridge_account: bridge_account,
        import_adapter: adapter
      ).process
      imported += 1 if result.present?
    rescue => e
      transaction_id = transaction.is_a?(Hash) ? (transaction[:id] || transaction["id"]) : nil
      Rails.logger.error("BridgeAccount::Transactions::Processor - Failed to process transaction #{transaction_id}: #{e.class} - #{e.message}")
    end

    @skipped_entries = adapter.skipped_entries

    {
      success: true,
      total: transactions.count,
      imported: imported,
      skipped_entries: skipped_entries
    }
  end
end
