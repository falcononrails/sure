class BridgeItem::SyncCompleteEvent
  attr_reader :bridge_item

  def initialize(bridge_item)
    @bridge_item = bridge_item
  end

  def broadcast
    bridge_item.reload

    bridge_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    bridge_item.broadcast_replace_to(
      bridge_item.family,
      target: "bridge_item_#{bridge_item.id}",
      partial: "bridge_items/bridge_item",
      locals: { bridge_item: bridge_item }
    )

    bridge_item.family.broadcast_sync_complete
  end
end
