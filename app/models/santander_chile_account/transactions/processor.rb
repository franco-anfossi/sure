# frozen_string_literal: true

require "digest"

class SantanderChileAccount::Transactions::Processor
  include SantanderChileAccount::DataHelpers

  attr_reader :santander_chile_account, :skipped_entries

  def initialize(santander_chile_account)
    @santander_chile_account = santander_chile_account
    @skipped_entries = []
  end

  def process
    unless santander_chile_account.raw_transactions_payload.present?
      Rails.logger.info "SantanderChileAccount::Transactions::Processor - No transactions in raw_transactions_payload for santander_chile_account #{santander_chile_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = santander_chile_account.raw_transactions_payload.count
    Rails.logger.info "SantanderChileAccount::Transactions::Processor - Processing #{total_count} transactions for santander_chile_account #{santander_chile_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []
    adapter = import_adapter

    santander_chile_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = process_transaction(transaction_data)

        if result.nil?
          failed_count += 1
          transaction_id = transaction_data.try(:[], :date) || transaction_data.try(:[], "date") || "unknown"
          errors << { index: index, transaction_id: transaction_id, error: "Skipped" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :date) || transaction_data.try(:[], "date") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "SantanderChileAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :date) || transaction_data.try(:[], "date") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "SantanderChileAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    @skipped_entries = adapter&.skipped_entries || []

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "SantanderChileAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "SantanderChileAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    def account
      @santander_chile_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_transaction(transaction_data)
      return nil unless account.present?

      data = transaction_data.with_indifferent_access

      external_id = build_external_id(data)
      return nil if external_id.blank?

      amount = parse_transaction_amount(data)
      return nil if amount.nil?

      date = parse_date(data[:date])
      return nil if date.nil?

      name = normalize_transaction_description(data[:description])
      currency = account.currency || "CLP"
      extra = build_extra_metadata(data)

      Rails.logger.info "SantanderChileAccount::Transactions::Processor - Importing transaction: id=#{external_id} amount=#{amount} date=#{date}"

      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name[0..254], # Limit to 255 chars
        source: "santander_chile",
        extra: extra
      )
    end

    def parse_transaction_amount(data)
      amount = parse_decimal(data[:amount])
      return nil if amount.nil?

      -amount
    end

    def build_extra_metadata(data)
      {
        "santander_chile" => {
          "source" => data[:source],
          "owner" => data[:owner],
          "installments" => data[:installments],
          "balance" => data[:balance],
          "account_id" => santander_chile_account.santander_chile_account_id,
          "account_name" => santander_chile_account.name
        }.compact
      }
    end

    def build_external_id(data)
      fingerprint = [
        santander_chile_account.santander_chile_account_id,
        data[:source],
        parse_date(data[:date])&.iso8601,
        normalize_transaction_description(data[:description]),
        parse_decimal(data[:amount])&.to_s("F"),
        data[:owner],
        data[:installments]
      ].join("|")

      "santander_chile_#{Digest::SHA256.hexdigest(fingerprint)}"
    end
end
