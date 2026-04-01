# frozen_string_literal: true

class SantanderChileItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :password, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :rut, :password, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :santander_chile_accounts, dependent: :destroy
  has_many :accounts, through: :santander_chile_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def syncer
    SantanderChileItem::Syncer.new(self)
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end


  # Import data from provider API
  def import_latest_santander_chile_data(sync: nil)
    provider = santander_chile_provider
    unless provider
      Rails.logger.error "SantanderChileItem #{id} - Cannot import: provider is not configured"
      raise StandardError, I18n.t("santander_chile_items.errors.provider_not_configured")
    end

    SantanderChileItem::Importer.new(self, santander_chile_provider: provider, sync: sync).import
  rescue => e
    Rails.logger.error "SantanderChileItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Process linked accounts after data import
  def process_accounts
    return [] if santander_chile_accounts.empty?

    results = []
    linked_santander_chile_accounts.includes(account_provider: :account).each do |santander_chile_account|
      begin
        result = SantanderChileAccount::Processor.new(santander_chile_account).process
        results << { santander_chile_account_id: santander_chile_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "SantanderChileItem #{id} - Failed to process account #{santander_chile_account.id}: #{e.message}"
        results << { santander_chile_account_id: santander_chile_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Schedule sync jobs for all linked accounts
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "SantanderChileItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_santander_chile_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_santander_chile_accounts
    santander_chile_accounts.joins(:account_provider)
  end

  # Unlinked accounts (no AccountProvider association)
  def unlinked_santander_chile_accounts
    santander_chile_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("santander_chile_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("santander_chile_items.sync_status.synced", count: linked_count)
    else
      I18n.t("santander_chile_items.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    santander_chile_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    santander_chile_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    santander_chile_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    santander_chile_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("santander_chile_items.institution_summary.none")
    else
      I18n.t("santander_chile_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    rut.present? && password.present?
  end
end
