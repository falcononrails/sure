module Family::BridgeConnectable
  extend ActiveSupport::Concern

  included do
    has_many :bridge_items, dependent: :destroy
  end

  def can_connect_bridge?
    bridge_provider.present?
  end

  private
    def bridge_provider
      Provider::Registry.get_provider(:bridge)
    end
end
