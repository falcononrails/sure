module BridgeItem::Provided
  extend ActiveSupport::Concern

  def bridge_provider
    @bridge_provider ||= Provider::Registry.get_provider(:bridge)
  end
end
