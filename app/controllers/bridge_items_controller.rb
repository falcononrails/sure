class BridgeItemsController < ApplicationController
  before_action :set_bridge_item, only: %i[edit start_connect destroy sync setup_accounts complete_account_setup]

  def new
    provider = bridge_provider
    return redirect_to(accounts_path, alert: "Bridge is not configured.") unless provider
    return unless ensure_connect_email!

    @bridge_item = Current.family.bridge_items.new(name: "Bridge connection")
    @form_url = bridge_items_path
    @submit_label = "Continue to Bridge"
    render layout: false
  end

  def create
    provider = bridge_provider
    return redirect_to(accounts_path, alert: "Bridge is not configured.") unless provider
    return unless ensure_connect_email!

    @bridge_item = Current.family.bridge_items.new(
      name: "Bridge connection",
      bridge_external_user_id: bridge_item_params[:bridge_external_user_id].to_s.strip
    )

    if @bridge_item.bridge_external_user_id.blank?
      @form_url = bridge_items_path
      @submit_label = "Continue to Bridge"
      @error_message = "Enter the Bridge external_user_id you created before opening Bridge Connect."
      render :new, layout: false, status: :unprocessable_entity
      return
    end

    @bridge_item.save!
    @connect_url = create_connect_url(@bridge_item, provider: provider)
    render partial: "bridge_items/connect_redirect", formats: :html, layout: false
  rescue ActiveRecord::RecordInvalid => e
    @form_url = bridge_items_path
    @submit_label = "Continue to Bridge"
    @error_message = e.record.errors.full_messages.to_sentence
    render :new, layout: false, status: :unprocessable_entity
  rescue Provider::Bridge::BridgeError => e
    @bridge_item&.destroy if @bridge_item&.persisted? && @bridge_item.pending_connect?
    @form_url = bridge_items_path
    @submit_label = "Continue to Bridge"
    @error_message = "Failed to create Bridge connect session: #{e.message}"
    render :new, layout: false, status: :unprocessable_entity
  end

  def edit
    provider = bridge_provider
    return redirect_to(accounts_path, alert: "Bridge is not configured.") unless provider
    return unless ensure_connect_email!

    if @bridge_item.bridge_external_user_id.blank?
      @form_url = start_connect_bridge_item_path(@bridge_item)
      @submit_label = "Reconnect with Bridge"
      render layout: false
      return
    end

    if @bridge_item.bridge_item_id.blank?
      redirect_to accounts_path, alert: "This Bridge connection is not ready to reconnect."
      return
    end

    @connect_url = create_connect_url(@bridge_item, provider: provider, item_id: @bridge_item.bridge_item_id)
    render layout: false
  rescue Provider::Bridge::BridgeError => e
    redirect_to accounts_path, alert: "Failed to reopen Bridge connect session: #{e.message}"
  end

  def start_connect
    provider = bridge_provider
    return redirect_to(accounts_path, alert: "Bridge is not configured.") unless provider
    return unless ensure_connect_email!

    @bridge_item.update!(bridge_external_user_id: bridge_item_params[:bridge_external_user_id].to_s.strip)

    if @bridge_item.bridge_external_user_id.blank?
      @form_url = start_connect_bridge_item_path(@bridge_item)
      @submit_label = "Reconnect with Bridge"
      @error_message = "Enter the Bridge external_user_id you created before opening Bridge Connect."
      render :edit, layout: false, status: :unprocessable_entity
      return
    end

    @connect_url = create_connect_url(@bridge_item, provider: provider, item_id: @bridge_item.bridge_item_id.presence)
    render partial: "bridge_items/connect_redirect", formats: :html, layout: false
  rescue ActiveRecord::RecordInvalid => e
    @form_url = start_connect_bridge_item_path(@bridge_item)
    @submit_label = "Reconnect with Bridge"
    @error_message = e.record.errors.full_messages.to_sentence
    render :edit, layout: false, status: :unprocessable_entity
  rescue Provider::Bridge::BridgeError => e
    @form_url = start_connect_bridge_item_path(@bridge_item)
    @submit_label = "Reconnect with Bridge"
    @error_message = "Failed to create Bridge connect session: #{e.message}"
    render :edit, layout: false, status: :unprocessable_entity
  end

  def callback
    bridge_item = resolve_bridge_item_from_context

    unless bridge_item
      redirect_to accounts_path, alert: "Unable to match the Bridge callback to a connection."
      return
    end

    success = params[:success]
    connect_succeeded = success.nil? || ActiveModel::Type::Boolean.new.cast(success)

    if params[:error].present? || !connect_succeeded || params[:item_id].blank?
      cleanup_pending_item!(bridge_item)
      redirect_to accounts_path, alert: "Bridge connection was not completed."
      return
    end

    bridge_item.update!(
      bridge_item_id: params[:item_id].to_s,
      status: :good,
      scheduled_for_deletion: false
    )

    bridge_item.sync_later unless bridge_item.syncing?

    redirect_to accounts_path, notice: "Bridge connection started. Your accounts are syncing."
  end

  def destroy
    @bridge_item.destroy_later
    redirect_to accounts_path, notice: "Bridge accounts scheduled for deletion."
  end

  def sync
    @bridge_item.sync_later unless @bridge_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @bridge_accounts = @bridge_item.bridge_accounts
      .active_data_access
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    @account_type_options = [
      [ "Skip this account", "skip" ],
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    @subtype_options = {
      "Depository" => {
        label: "Account subtype:",
        options: Depository::SUBTYPES.map { |key, value| [ value[:long], key ] }
      },
      "CreditCard" => {
        label: "",
        options: [],
        message: "Credit cards will be set up automatically."
      },
      "Investment" => {
        label: "Investment type:",
        options: Investment::SUBTYPES.map { |key, value| [ value[:long], key ] }
      },
      "Loan" => {
        label: "Loan type:",
        options: Loan::SUBTYPES.map { |key, value| [ value[:long], key ] }
      },
      "OtherAsset" => {
        label: nil,
        options: [],
        message: "Other assets will be created as generic assets."
      }
    }

    render layout: false
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}
    valid_types = %w[Depository CreditCard Investment Loan OtherAsset]
    created_accounts = 0

    ActiveRecord::Base.transaction do
      account_types.each do |bridge_account_id, selected_type|
        next if selected_type.blank? || selected_type == "skip"
        next unless valid_types.include?(selected_type)

        bridge_account = @bridge_item.bridge_accounts.active_data_access.find_by(id: bridge_account_id)
        next unless bridge_account
        next if bridge_account.account_provider.present?

        selected_subtype = account_subtypes[bridge_account_id]
        selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

        account = Account.create_and_sync(
          {
            family: Current.family,
            name: bridge_account.name,
            balance: bridge_account.current_balance || 0,
            cash_balance: bridge_account.current_balance || 0,
            currency: bridge_account.currency || "EUR",
            accountable_type: selected_type,
            accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
          },
          skip_initial_sync: true
        )

        AccountProvider.create!(account: account, provider: bridge_account)
        created_accounts += 1
      end
    end

    @bridge_item.update!(pending_account_setup: @bridge_item.unlinked_accounts_count.positive?)
    @bridge_item.sync_later if created_accounts.positive? && !@bridge_item.syncing?

    if created_accounts.positive?
      redirect_to accounts_path, notice: "#{created_accounts} Bridge #{'account'.pluralize(created_accounts)} linked successfully."
    else
      redirect_to accounts_path, alert: "No Bridge accounts were linked."
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to setup_accounts_bridge_item_path(@bridge_item), alert: "Failed to set up Bridge accounts: #{e.message}"
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    @available_bridge_accounts = Current.family.bridge_items
      .includes(:bridge_accounts)
      .flat_map(&:bridge_accounts)
      .select do |bridge_account|
        bridge_account.data_access != "disabled" &&
          bridge_account.account_provider.nil? &&
          bridge_account.account.nil?
      end

    if @available_bridge_accounts.empty?
      redirect_to account_path(@account), alert: "No available Bridge accounts to link. Connect Bridge first or sync again."
      return
    end

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])

    if account.account_providers.exists?
      redirect_to accounts_path, alert: "This account is already linked to a provider."
      return
    end

    bridge_account = BridgeAccount.find(params[:bridge_account_id])

    unless Current.family.bridge_items.exists?(id: bridge_account.bridge_item_id)
      redirect_to accounts_path, alert: "Invalid Bridge account selected."
      return
    end

    if bridge_account.data_access == "disabled"
      redirect_to accounts_path, alert: "This Bridge account no longer has data access."
      return
    end

    if bridge_account.account_provider.present?
      redirect_to accounts_path, alert: "This Bridge account is already linked."
      return
    end

    AccountProvider.create!(account: account, provider: bridge_account)
    bridge_account.bridge_item.sync_later unless bridge_account.bridge_item.syncing?

    redirect_to accounts_path, notice: "Account successfully linked to Bridge."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to accounts_path, alert: "Failed to link Bridge account: #{e.message}"
  end

  private
    def set_bridge_item
      @bridge_item = Current.family.bridge_items.find(params[:id])
    end

    def bridge_provider
      Provider::Registry.get_provider(:bridge)
    end

    def ensure_connect_email!
      return true if Current.user.email.present?

      redirect_to accounts_path, alert: "Bridge requires an email address on your signed-in user before you can connect an institution."
      false
    end

    def create_connect_url(bridge_item, provider:, item_id: nil)
      access_token = provider.ensure_user_access_token!(
        external_user_id: bridge_item.bridge_user_external_id,
        user_email: Current.user.email
      )

      response = provider.create_connect_session(
        access_token: access_token,
        user_email: Current.user.email,
        callback_url: callback_bridge_items_url,
        account_types: "all",
        item_id: item_id,
        context: bridge_item.connect_context
      )

      connect_url = response[:url] || response["url"]
      raise Provider::Bridge::BridgeError.new("Bridge did not return a connect URL", :invalid_response) if connect_url.blank?

      connect_url
    end

    def resolve_bridge_item_from_context
      context = params[:context]
      return nil if context.blank?

      bridge_item = Current.family.bridge_items.find_by(id: context)
      return bridge_item if bridge_item

      legacy_bridge_item = BridgeItem.find_signed(context, purpose: :bridge_connect)
      return nil unless legacy_bridge_item

      Current.family.bridge_items.find_by(id: legacy_bridge_item.id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def cleanup_pending_item!(bridge_item)
      return unless bridge_item.pending_connect?
      return if bridge_item.bridge_item_id.present?

      bridge_item.destroy
    end

    def bridge_item_params
      params.fetch(:bridge_item, {}).permit(:bridge_external_user_id)
    end
end
