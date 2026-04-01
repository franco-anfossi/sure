class Provider::SantanderChileAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("SantanderChileAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_santander_chile?

    [ {
      key: "santander_chile",
      name: "Santander Chile",
      description: "Connect Santander Chile using the local open-banking-chile scraper",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.preload_accounts_santander_chile_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_santander_chile_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "santander_chile"
  end

  def self.build_provider(family: nil)
    return nil unless family.present?

    santander_chile_item = family.santander_chile_items.order(created_at: :desc).first
    return nil unless santander_chile_item&.credentials_configured?

    Provider::SantanderChile.new(
      rut: santander_chile_item.rut,
      password: santander_chile_item.password,
      chrome_path: santander_chile_item.chrome_path,
      two_factor_timeout_sec: santander_chile_item.two_factor_timeout_sec
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_santander_chile_item_path(item)
  end

  def item
    provider_account.santander_chile_item
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for SantanderChile account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
