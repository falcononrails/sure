class BridgeItem::Syncer
  include SyncStats::Collector

  attr_reader :bridge_item

  def initialize(bridge_item)
    @bridge_item = bridge_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Importing accounts from Bridge...") if sync.respond_to?(:status_text)
    mark_import_started(sync)
    import_result = bridge_item.import_latest_bridge_data

    unless import_result[:success]
      collect_health_stats(sync, errors: [ { message: import_result[:error], category: "bridge_import" } ])
      return if import_result[:requires_update]

      raise StandardError, import_result[:error].presence || "Bridge import failed"
    end

    sync.update!(status_text: "Processing Bridge accounts...") if sync.respond_to?(:status_text)
    processing_results = bridge_item.process_accounts
    skipped_entries = processing_results.flat_map { |result| result[:skipped_entries].to_a }

    provider_accounts = bridge_item.bridge_accounts.active_data_access
    collect_setup_stats(sync, provider_accounts: provider_accounts)

    if bridge_item.unlinked_accounts_count.positive?
      bridge_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{bridge_item.unlinked_accounts_count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      bridge_item.update!(pending_account_setup: false)
    end

    linked_account_ids = bridge_item.bridge_accounts
      .active_data_access
      .includes(:account_provider)
      .filter_map { |account| account.current_account&.id }

    if linked_account_ids.any?
      bridge_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      collect_transaction_stats(sync, account_ids: linked_account_ids, source: "bridge")
      collect_skip_stats(sync, skipped_entries: skipped_entries) if skipped_entries.any?
    end

    collect_health_stats(sync, errors: nil)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end
end
