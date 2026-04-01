# frozen_string_literal: true

class SantanderChileConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(santander_chile_item_id:, account_id:)
    Rails.logger.info(
      "SantanderChileConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    santander_chile_item = SantanderChileItem.find_by(id: santander_chile_item_id)
    return unless santander_chile_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("SantanderChileConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "SantanderChileConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
