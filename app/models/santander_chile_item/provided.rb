# frozen_string_literal: true

module SantanderChileItem::Provided
  extend ActiveSupport::Concern

  def santander_chile_provider
    return nil unless credentials_configured?

    Provider::SantanderChile.new(
      rut: rut,
      password: password,
      chrome_path: chrome_path,
      two_factor_timeout_sec: two_factor_timeout_sec
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def santander_chile_credentials
    return nil unless credentials_configured?

    {
      rut: rut,
      password: password,
      chrome_path: chrome_path,
      two_factor_timeout_sec: two_factor_timeout_sec
    }
  end
end
