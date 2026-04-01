# frozen_string_literal: true

class SantanderChileItem::SyncCompleteEvent
  attr_reader :santander_chile_item

  def initialize(santander_chile_item)
    @santander_chile_item = santander_chile_item
  end

  def broadcast
    santander_chile_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    santander_chile_item.broadcast_replace_to(
      santander_chile_item.family,
      target: "santander_chile_item_#{santander_chile_item.id}",
      partial: "santander_chile_items/santander_chile_item",
      locals: { santander_chile_item: santander_chile_item }
    )

    santander_chile_item.family.broadcast_sync_complete
  end
end
