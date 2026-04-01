# frozen_string_literal: true

class SantanderChileItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard].freeze

  before_action :set_santander_chile_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @santander_chile_items = Current.family.santander_chile_items.ordered
  end

  def show
  end

  def new
    @santander_chile_item = Current.family.santander_chile_items.build
  end

  def edit
  end

  def create
    @santander_chile_item = Current.family.santander_chile_items.build(santander_chile_item_params)
    @santander_chile_item.name ||= "SantanderChile Connection"

    if @santander_chile_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured SantanderChile.")
        @santander_chile_items = Current.family.santander_chile_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "santander_chile-providers-panel",
            partial: "settings/providers/santander_chile_panel",
            locals: { santander_chile_items: @santander_chile_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @santander_chile_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "santander_chile-providers-panel",
          partial: "settings/providers/santander_chile_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @santander_chile_item.update(santander_chile_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated SantanderChile configuration.")
        @santander_chile_items = Current.family.santander_chile_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "santander_chile-providers-panel",
            partial: "settings/providers/santander_chile_panel",
            locals: { santander_chile_items: @santander_chile_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @santander_chile_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "santander_chile-providers-panel",
          partial: "settings/providers/santander_chile_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @santander_chile_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled SantanderChile connection for deletion.")
  end

  def sync
    unless @santander_chile_item.syncing?
      @santander_chile_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    santander_chile_item = current_santander_chile_item
    unless santander_chile_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    fetch_accounts_synchronously(santander_chile_item)
    redirect_to select_accounts_santander_chile_items_path(accountable_type: params[:accountable_type], return_to: safe_return_to_path)
  rescue Provider::SantanderChile::Error => e
    redirect_to settings_providers_path, alert: e.message
  end

  def select_accounts
    @accountable_type = validated_accountable_type(params[:accountable_type] || "Depository")
    @return_to = safe_return_to_path

    santander_chile_item = current_santander_chile_item
    unless santander_chile_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    fetch_accounts_synchronously(santander_chile_item) if santander_chile_item.santander_chile_accounts.none?
    @santander_chile_accounts = available_provider_accounts(
      santander_chile_item,
      accountable_type: @accountable_type
    )

    render layout: false
  end

  def link_accounts
    santander_chile_item = current_santander_chile_item
    unless santander_chile_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_santander_chile_items_path(accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".no_accounts_selected")
      return
    end

    accountable_type = validated_accountable_type(params[:accountable_type] || "Depository")
    return_to = safe_return_to_path
    created_count = 0

    santander_chile_item.santander_chile_accounts.where(id: selected_ids).find_each do |santander_chile_account|
      if santander_chile_account.account_provider.present?
        next
      end

      if santander_chile_account.name.blank?
        next
      end

      account = create_linked_account(santander_chile_account, accountable_type: accountable_type)
      santander_chile_account.ensure_account_provider!(account)
      process_provider_account!(santander_chile_account)
      created_count += 1
    rescue => e
      Rails.logger.error "SantanderChileItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      redirect_to return_to || accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_santander_chile_items_path(accountable_type: accountable_type, return_to: return_to), alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    if @account.account_providers.exists?
      redirect_to account_path(@account), alert: t(".account_already_linked")
      return
    end

    @return_to = safe_return_to_path
    @santander_chile_item = current_santander_chile_item

    unless @santander_chile_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    fetch_accounts_synchronously(@santander_chile_item)
    @santander_chile_accounts = available_provider_accounts(
      @santander_chile_item,
      accountable_type: @account.accountable_type
    )

    render layout: false
  rescue Provider::SantanderChile::Error => e
    redirect_to account_path(@account), alert: e.message
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    return_to = safe_return_to_path
    santander_chile_item = current_santander_chile_item

    unless santander_chile_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    if account.account_providers.exists?
      redirect_to account_path(account), alert: t(".account_already_linked")
      return
    end

    santander_chile_account = santander_chile_item.santander_chile_accounts.find(params[:santander_chile_account_id])

    if santander_chile_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    santander_chile_account.ensure_account_provider!(account)
    process_provider_account!(santander_chile_account)

    redirect_to return_to || account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @santander_chile_item.unlinked_santander_chile_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
      return
    end
  end

  def complete_account_setup
    selected_ids = params[:account_ids] || []
    if selected_ids.empty?
      redirect_to setup_accounts_santander_chile_item_path(@santander_chile_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0
    sync_start_dates = params[:sync_start_dates] || {}

    selected_ids.each do |santander_chile_account_id|
      santander_chile_account = @santander_chile_item.santander_chile_accounts.find_by(id: santander_chile_account_id)
      next unless santander_chile_account
      next if santander_chile_account.account_provider.present?

      accountable_type = infer_accountable_type_from_provider(santander_chile_account)
      account = create_linked_account(santander_chile_account, accountable_type: accountable_type)

      if account&.persisted?
        santander_chile_account.ensure_account_provider!(account)
        sync_start_date = sync_start_dates[santander_chile_account.id.to_s]
        santander_chile_account.update!(sync_start_date: sync_start_date) if sync_start_date.present?
        process_provider_account!(santander_chile_account)
        created_count += 1
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "SantanderChileItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_santander_chile_item_path(@santander_chile_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_santander_chile_item
      @santander_chile_item = Current.family.santander_chile_items.find(params[:id])
    end

    def santander_chile_item_params
      attributes = params.require(:santander_chile_item).permit(
        :name,
        :sync_start_date,
        :rut,
        :password,
        :chrome_path,
        :two_factor_timeout_sec
      )

      if action_name == "update"
        %i[rut password chrome_path two_factor_timeout_sec].each do |field|
          attributes.delete(field) if attributes[field].blank?
        end
      end

      attributes
    end

    def create_linked_account(santander_chile_account, accountable_type:)
      accountable_class = validated_accountable_class(accountable_type)
      accountable = accountable_class.new(accountable_attributes_for(santander_chile_account, accountable_type))
      balance = santander_chile_account.current_balance || 0

      account = Current.family.accounts.create!(
        name: santander_chile_account.name,
        balance: balance,
        cash_balance: balance,
        currency: santander_chile_account.currency || "CLP",
        classification: accountable_class.classification,
        accountable: accountable
      )
      account.auto_share_with_family! if Current.family.share_all_by_default?
      account
    end

    def accountable_attributes_for(santander_chile_account, accountable_type)
      case accountable_type
      when "CreditCard"
        available_credit = santander_chile_account.raw_payload&.dig("national", "available") ||
                           santander_chile_account.raw_payload&.dig(:national, :available)
        {
          subtype: "credit_card",
          available_credit: available_credit
        }.compact
      else
        { subtype: "checking" }
      end
    end

    def infer_accountable_type_from_provider(santander_chile_account)
      santander_chile_account.account_type == "credit_card" ? "CreditCard" : "Depository"
    end

    def validated_accountable_type(accountable_type)
      unless ALLOWED_ACCOUNTABLE_TYPES.include?(accountable_type)
        raise ArgumentError, "Invalid accountable type: #{accountable_type}"
      end

      accountable_type
    end

    def validated_accountable_class(accountable_type)
      validated_accountable_type(accountable_type)

      accountable_type.constantize
    end

    def current_santander_chile_item
      Current.family.santander_chile_items.order(created_at: :desc).first
    end

    def available_provider_accounts(santander_chile_item, accountable_type:)
      scope = santander_chile_item.santander_chile_accounts
        .left_joins(:account_provider)
        .where(account_providers: { id: nil })
        .order(:name)

      case accountable_type
      when "CreditCard"
        scope.where(account_type: "credit_card")
      when "Depository"
        scope.where(account_type: "depository")
      else
        scope.none
      end
    end

    def fetch_accounts_synchronously(santander_chile_item)
      santander_chile_item.import_latest_santander_chile_data
    end

    def process_provider_account!(santander_chile_account)
      SantanderChileAccount::Processor.new(santander_chile_account).process
      santander_chile_account.current_account&.sync_later
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s

      begin
        uri = URI.parse(return_to)
        return nil if uri.scheme.present?
        return nil unless return_to.start_with?("/")

        return_to
      rescue URI::InvalidURIError
        nil
      end
    end
end
