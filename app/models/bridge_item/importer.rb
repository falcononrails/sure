class BridgeItem::Importer
  attr_reader :bridge_item, :bridge_provider

  def initialize(bridge_item, bridge_provider:)
    @bridge_item = bridge_item
    @bridge_provider = bridge_provider
  end

  def import
    sync_started_at = Time.current
    access_token = bridge_provider.ensure_user_access_token!(external_user_id: bridge_item.bridge_user_external_id)

    item_snapshot = bridge_provider.get_item(access_token: access_token, item_id: bridge_item.bridge_item_id)
    bridge_item.upsert_bridge_snapshot!(item_snapshot)
    upsert_institution_snapshot(item_snapshot)

    unless bridge_item.bridge_syncable?
      return {
        success: false,
        requires_update: true,
        error: bridge_item.status_code_description.presence || bridge_item.status_code_info.presence || "Bridge connection requires update"
      }
    end

    accounts = import_accounts!(access_token)
    transactions = import_transactions!(access_token)

    bridge_item.update!(
      transactions_synced_at: sync_started_at,
      status: :good
    )

    {
      success: true,
      accounts_imported: accounts[:imported],
      transactions_imported: transactions[:imported]
    }
  rescue Provider::Bridge::BridgeError => e
    if %i[unauthorized not_found access_forbidden].include?(e.error_type)
      bridge_item.update!(
        status: :requires_update,
        status_code_description: e.message
      )
    end

    {
      success: false,
      error: e.message,
      requires_update: bridge_item.requires_update?
    }
  end

  private
    def upsert_institution_snapshot(item_snapshot)
      provider_id = item_snapshot.with_indifferent_access[:provider_id]
      return if provider_id.blank?

      provider_snapshot = bridge_provider.get_provider(provider_id: provider_id)
      bridge_item.upsert_bridge_institution_snapshot!(provider_snapshot)
    rescue Provider::Bridge::BridgeError => e
      Rails.logger.warn("BridgeItem::Importer - Failed to fetch provider #{provider_id} for item #{bridge_item.id}: #{e.message}")
    end

    def import_accounts!(access_token)
      imported = 0
      item_accounts = bridge_provider.list_accounts(access_token: access_token).select do |account|
        account.with_indifferent_access[:item_id].to_s == bridge_item.bridge_item_id.to_s
      end

      item_accounts.each do |account_snapshot|
        snapshot = account_snapshot.with_indifferent_access
        next if snapshot[:id].blank?

        bridge_account = bridge_item.bridge_accounts.find_or_initialize_by(
          bridge_account_id: snapshot[:id]&.to_s
        )
        bridge_account.upsert_bridge_snapshot!(account_snapshot)
        imported += 1
      end

      { imported: imported }
    end

    def import_transactions!(access_token)
      imported = 0
      since = bridge_item.transactions_synced_at
      account_ids = bridge_item.bridge_accounts.active_data_access.pluck(:bridge_account_id).map(&:to_s)
      return { imported: 0 } if account_ids.empty?

      transactions = bridge_provider.list_transactions(access_token: access_token, since: since)
      grouped_transactions = transactions.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |transaction, groups|
        snapshot = transaction.with_indifferent_access
        account_id = snapshot[:account_id].to_s
        next unless account_ids.include?(account_id)

        groups[account_id] << transaction
        imported += 1
      end

      grouped_transactions.each do |account_id, account_transactions|
        bridge_account = bridge_item.bridge_accounts.find_by(bridge_account_id: account_id)
        next unless bridge_account

        bridge_account.upsert_bridge_transactions_snapshot!(account_transactions)
      end

      { imported: imported }
    end
end
