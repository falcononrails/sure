class BridgeItem < ApplicationRecord
  include Syncable, Provided, Encryptable

  SYNCABLE_BRIDGE_STATUSES = [ 0, -2, -3 ].freeze

  enum :status, { pending_connect: "pending_connect", good: "good", requires_update: "requires_update" }, default: :pending_connect

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :bridge_accounts, dependent: :destroy
  has_many :accounts, through: :bridge_accounts

  validates :name, presence: true
  validates :bridge_item_id, uniqueness: true, allow_nil: true

  before_destroy :remove_bridge_item

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(bridge_item_id: nil).where.not(status: :pending_connect) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_bridge_data
    raise StandardError, "Bridge provider is not configured" unless bridge_provider

    BridgeItem::Importer.new(self, bridge_provider: bridge_provider).import
  end

  def process_accounts
    bridge_accounts.active_data_access.includes(:account_provider, :account).map do |bridge_account|
      BridgeAccount::Processor.new(bridge_account).process
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def upsert_bridge_snapshot!(item_snapshot)
    snapshot = item_snapshot.with_indifferent_access

    assign_attributes(
      bridge_status: snapshot[:status],
      status_code_info: snapshot[:status_code_info],
      status_code_description: snapshot[:status_code_description],
      authentication_expires_at: parse_time(snapshot[:authentication_expires_at]),
      raw_payload: item_snapshot
    )

    apply_bridge_status!
    save!
  end

  def upsert_bridge_institution_snapshot!(provider_snapshot)
    snapshot = provider_snapshot.with_indifferent_access

    assign_attributes(
      institution_id: snapshot[:id]&.to_s,
      institution_name: snapshot[:name],
      raw_institution_payload: provider_snapshot
    )

    self.name = institution_name.presence || name
    save!
  end

  def bridge_syncable?
    bridge_status.present? && SYNCABLE_BRIDGE_STATUSES.include?(bridge_status)
  end

  def linked_accounts_count
    bridge_accounts.active_data_access.joins(:account_provider).count
  end

  def unlinked_accounts_count
    bridge_accounts.active_data_access.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    bridge_accounts.active_data_access.count
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts.zero?
      "No accounts found"
    elsif unlinked_count.zero?
      "#{linked_count} #{'account'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end

  def institution_display_name
    institution_name.presence || name.presence || "Bridge connection"
  end

  def connect_context
    id
  end

  def bridge_user_external_id
    bridge_external_user_id.to_s.strip.presence || "sure-family-#{family_id}"
  end

  def primary_user_email
    family.users.where.not(email: [ nil, "" ]).order(:created_at).pick(:email)
  end

  private
    def apply_bridge_status!
      self.status = bridge_syncable? ? :good : :requires_update
    end

    def remove_bridge_item
      return if bridge_item_id.blank?
      return unless bridge_provider

      access_token = bridge_provider.ensure_user_access_token!(external_user_id: bridge_user_external_id)
      bridge_provider.delete_item(access_token: access_token, item_id: bridge_item_id)
    rescue Provider::Bridge::BridgeError => e
      ignorable = %i[not_found unauthorized access_forbidden]
      return if ignorable.include?(e.error_type)

      Rails.logger.warn("Failed to delete Bridge item #{id}: #{e.error_type} - #{e.message}")
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
end
