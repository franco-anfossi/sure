# frozen_string_literal: true

class SantanderChileAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include SantanderChileAccount::DataHelpers

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    encrypts :institution_metadata
  end

  belongs_to :santander_chile_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :santander_chile_account_id, uniqueness: { scope: :santander_chile_item_id, allow_nil: true }

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  def upsert_from_santander_chile!(account_data)
    data = sdk_object_to_hash(account_data).with_indifferent_access

    update!(
      santander_chile_account_id: (data[:id] || data[:account_id] || data[:santander_chile_account_id])&.to_s,
      account_number: (data[:account_number] || data[:last4])&.to_s.presence,
      name: data[:name] || data[:label] || "Santander Chile Account",
      current_balance: parse_decimal(data[:balance] || data[:current_balance] || 0),
      currency: extract_currency(data, fallback: "CLP"),
      account_status: data[:status] || data[:account_status] || "active",
      account_type: data[:type] || data[:account_type],
      provider: data[:provider] || "Santander Chile",
      institution_metadata: extract_institution_metadata(data),
      raw_payload: sdk_object_to_hash(account_data).except("transactions", :transactions)
    )
  end

  def upsert_santander_chile_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def extract_institution_metadata(data)
      {
        id: data[:institution_id] || data.dig(:institution, :id),
        name: data[:institution_name] || data.dig(:institution, :name),
        logo: data[:institution_logo] || data.dig(:institution, :logo),
        domain: data[:institution_domain] || data.dig(:institution, :domain),
        url: data[:institution_url] || data.dig(:institution, :url),
        color: data[:institution_color] || data.dig(:institution, :color)
      }.compact
    end

    def enqueue_connection_cleanup
      return unless santander_chile_item

      SantanderChileConnectionCleanupJob.perform_later(
        santander_chile_item_id: santander_chile_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for SantanderChile account #{id}, defaulting to CLP")
    end
end
