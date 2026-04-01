# frozen_string_literal: true

class SantanderChileItem::Importer
  include SyncStats::Collector
  include SantanderChileAccount::DataHelpers

  ACCOUNT_SOURCE = "account"
  CREDIT_CARD_SOURCES = %w[credit_card_unbilled credit_card_billed].freeze
  INSTITUTION_METADATA = {
    id: "santander_chile",
    name: "Santander Chile",
    domain: "santander.cl",
    url: "https://banco.santander.cl/personas",
    color: "#E30000"
  }.freeze

  attr_reader :santander_chile_item, :santander_chile_provider, :sync

  def initialize(santander_chile_item, santander_chile_provider:, sync: nil)
    @santander_chile_item = santander_chile_item
    @santander_chile_provider = santander_chile_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "SantanderChileItem::Importer - Starting import for item #{santander_chile_item.id}"

    credentials = santander_chile_item.santander_chile_credentials
    unless credentials
      raise CredentialsError, "No SantanderChile credentials configured for item #{santander_chile_item.id}"
    end

    snapshot = santander_chile_provider.scrape_snapshot

    stats["api_requests"] = 1
    stats["total_movements"] = snapshot[:movements].to_a.count

    import_snapshot(snapshot)
    persist_stats!
  rescue Provider::SantanderChile::AuthenticationError => e
    santander_chile_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_snapshot(snapshot)
      sanitized_snapshot = snapshot.except(:screenshot, :debug)
      movements = snapshot[:movements].to_a.map { |movement| sdk_object_to_hash(movement).with_indifferent_access }
      checking_movements = movements.select { |movement| movement[:source] == ACCOUNT_SOURCE }
      credit_card_movements = movements.select { |movement| CREDIT_CARD_SOURCES.include?(movement[:source].to_s) }
      credit_cards = snapshot[:creditCards].to_a.map { |card| sdk_object_to_hash(card).with_indifferent_access }

      provider_accounts = []

      if snapshot[:balance].present? || checking_movements.any?
        provider_accounts << {
          id: "checking_clp",
          name: "Santander Corriente",
          balance: snapshot[:balance] || 0,
          currency: "CLP",
          type: "depository",
          status: "active",
          provider: "Santander Chile",
          institution: INSTITUTION_METADATA,
          raw_payload: {
            kind: "checking",
            balance: snapshot[:balance],
            movement_count: checking_movements.size
          },
          transactions: checking_movements
        }
      end

      if credit_cards.any?
        credit_cards.each_with_index do |card, index|
          national = (card[:national] || {}).with_indifferent_access
          provider_accounts << {
            id: "credit_card_#{slugify_label(card[:label])}",
            last4: card[:label].to_s[/(\d{4})(?!.*\d)/, 1],
            name: card[:label].presence || "Santander Credit Card",
            balance: national[:used] || 0,
            currency: "CLP",
            type: "credit_card",
            status: "active",
            provider: "Santander Chile",
            institution: INSTITUTION_METADATA,
            raw_payload: card.merge(
              kind: "credit_card",
              default_transactions_owner: index.zero? ? "primary" : "secondary",
              movement_count: index.zero? && credit_cards.one? ? credit_card_movements.size : 0
            ),
            transactions: index.zero? && credit_cards.one? ? credit_card_movements : []
          }
        end
      elsif credit_card_movements.any?
        existing_credit_card = primary_credit_card_account

        provider_accounts << {
          id: existing_credit_card&.santander_chile_account_id || "credit_card_primary",
          name: existing_credit_card&.name.presence || "Santander Credit Card",
          balance: existing_credit_card&.current_balance || 0,
          currency: "CLP",
          type: "credit_card",
          status: "active",
          provider: "Santander Chile",
          institution: INSTITUTION_METADATA,
          raw_payload: {
            kind: "credit_card",
            movement_count: credit_card_movements.size
          },
          transactions: credit_card_movements
        }
      end

      stats["total_accounts"] = provider_accounts.size
      upstream_account_ids = []

      provider_accounts.each do |provider_account_data|
        provider_account = santander_chile_item.santander_chile_accounts.find_or_initialize_by(
          santander_chile_account_id: provider_account_data[:id]
        )
        provider_account.upsert_from_santander_chile!(provider_account_data)
        provider_account.upsert_santander_chile_transactions_snapshot!(provider_account_data[:transactions])
        upstream_account_ids << provider_account_data[:id]
      rescue => e
        Rails.logger.error "SantanderChileItem::Importer - Failed to import account #{provider_account_data[:id]}: #{e.message}"
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        register_error(e, provider_account_id: provider_account_data[:id])
      else
        stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
      end

      prune_removed_accounts(upstream_account_ids)

      santander_chile_item.update!(
        status: :good,
        institution_id: INSTITUTION_METADATA[:id],
        institution_name: INSTITUTION_METADATA[:name],
        institution_domain: INSTITUTION_METADATA[:domain],
        institution_url: INSTITUTION_METADATA[:url],
        institution_color: INSTITUTION_METADATA[:color],
        raw_institution_payload: INSTITUTION_METADATA,
        raw_payload: sanitized_snapshot
      )
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      removed = santander_chile_item.santander_chile_accounts
        .without_linked
        .where.not(santander_chile_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "SantanderChileItem::Importer - Pruning #{removed.count} unlinked removed accounts"
        removed.destroy_all
      end
    end

    def primary_credit_card_account
      santander_chile_item.santander_chile_accounts
        .where(account_type: "credit_card")
        .left_joins(:account_provider)
        .order(Arel.sql("CASE WHEN account_providers.id IS NULL THEN 1 ELSE 0 END"), :created_at)
        .first
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context,
        timestamp: Time.current.iso8601
      }
    end
end
