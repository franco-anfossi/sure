module Family::SantanderChileConnectable
  extend ActiveSupport::Concern

  included do
    has_many :santander_chile_items, dependent: :destroy
  end

  def can_connect_santander_chile?
    # Families can configure their own SantanderChile credentials
    true
  end

  def create_santander_chile_item!(password:, rut: nil, chrome_path: nil, two_factor_timeout_sec: nil, item_name: nil)
    santander_chile_item = santander_chile_items.create!(
      name: item_name || "Santander Chile Connection",
      rut: rut,
      password: password,
      chrome_path: chrome_path,
      two_factor_timeout_sec: two_factor_timeout_sec
    )

    santander_chile_item.sync_later

    santander_chile_item
  end

  def has_santander_chile_credentials?
    santander_chile_items.where.not(password: nil).exists?
  end
end
