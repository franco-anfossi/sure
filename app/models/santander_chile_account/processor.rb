# frozen_string_literal: true

class SantanderChileAccount::Processor
  include SantanderChileAccount::DataHelpers

  attr_reader :santander_chile_account

  def initialize(santander_chile_account)
    @santander_chile_account = santander_chile_account
  end

  def process
    account = santander_chile_account.current_account
    return unless account

    Rails.logger.info "SantanderChileAccount::Processor - Processing account #{santander_chile_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Process transactions
    transactions_count = santander_chile_account.raw_transactions_payload&.size || 0
    Rails.logger.info "SantanderChileAccount::Processor - Transactions payload has #{transactions_count} items"

    if santander_chile_account.raw_transactions_payload.present?
      Rails.logger.info "SantanderChileAccount::Processor - Processing transactions..."
      transactions_processor.process
    else
      Rails.logger.warn "SantanderChileAccount::Processor - No transactions payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "SantanderChileAccount::Processor - Broadcast sync complete for account #{account.id}"

    {
      transactions_processed: transactions_count > 0,
      skipped_entries: transactions_processor.skipped_entries
    }
  end

  private

    def transactions_processor
      @transactions_processor ||= SantanderChileAccount::Transactions::Processor.new(santander_chile_account)
    end

    def update_account_balance(account)
      balance = santander_chile_account.current_balance || 0

      Rails.logger.info "SantanderChileAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: santander_chile_account.currency || account.currency
      )
      account.save!

      account.set_current_balance(balance)

      return unless account.accountable_type == "CreditCard"

      available_credit = parse_decimal(
        santander_chile_account.raw_payload&.dig("national", "available") ||
        santander_chile_account.raw_payload&.dig(:national, :available)
      )
      return if available_credit.nil?

      Account::ProviderImportAdapter.new(account).update_accountable_attributes(
        attributes: { available_credit: available_credit },
        source: "santander_chile"
      )
    end
end
