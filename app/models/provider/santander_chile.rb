# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

class Provider::SantanderChile
  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  DEFAULT_TIMEOUT_SEC = 90

  attr_reader :rut, :password, :chrome_path, :two_factor_timeout_sec

  def initialize(rut:, password:, chrome_path: nil, two_factor_timeout_sec: nil)
    @rut = rut.to_s
    @password = password.to_s
    @chrome_path = chrome_path.presence
    @two_factor_timeout_sec = (two_factor_timeout_sec.presence || DEFAULT_TIMEOUT_SEC).to_i
    validate_configuration!
  end

  def scrape_snapshot
    stdout, stderr, status = Open3.capture3(
      command_env,
      node_binary,
      "--input-type=module",
      "-e",
      node_script,
      chdir: open_banking_chile_root.to_s
    )

    Rails.logger.info("SantanderChile provider stderr: #{stderr}") if stderr.present?

    unless status.success?
      raise Error.new(
        "open-banking-chile exited with status #{status.exitstatus}: #{stderr.presence || stdout.presence || 'unknown error'}",
        :execution_failed
      )
    end

    payload = JSON.parse(stdout)
    unless payload.is_a?(Hash)
      raise Error.new("Unexpected scraper payload format", :invalid_response)
    end

    unless payload["success"]
      raise classify_provider_error(payload["error"])
    end

    payload.deep_symbolize_keys
  rescue JSON::ParserError => e
    raise Error.new("Failed to parse scraper JSON: #{e.message}", :invalid_json)
  end

  private

    def validate_configuration!
      raise ConfigurationError.new("RUT is required", :missing_rut) if rut.blank?
      raise ConfigurationError.new("Password is required", :missing_password) if password.blank?
      raise ConfigurationError.new("open-banking-chile path not found: #{open_banking_chile_root}", :missing_repo) unless open_banking_chile_root.directory?
      raise ConfigurationError.new("open-banking-chile dist not found. Build the repo first: #{open_banking_chile_dist}", :missing_dist) unless open_banking_chile_dist.exist?
    end

    def node_binary
      ENV.fetch("NODE_BINARY", "node")
    end

    def open_banking_chile_root
      @open_banking_chile_root ||= Pathname.new(
        ENV.fetch("OPEN_BANKING_CHILE_PATH", Rails.root.join("..", "open-banking-chile").to_s)
      ).expand_path
    end

    def open_banking_chile_dist
      open_banking_chile_root.join("dist/index.js")
    end

    def command_env
      {
        "SANTANDER_RUT" => rut,
        "SANTANDER_PASS" => password,
        "SANTANDER_2FA_TIMEOUT_SEC" => two_factor_timeout_sec.to_s,
        "CHROME_PATH" => chrome_path.to_s
      }.compact
    end

    def node_script
      <<~JS
        const { santander } = await import("./dist/index.js");
        const result = await santander.scrape({
          rut: process.env.SANTANDER_RUT,
          password: process.env.SANTANDER_PASS,
          chromePath: process.env.CHROME_PATH || undefined,
          saveScreenshots: false,
          headful: false
        });
        process.stdout.write(JSON.stringify(result));
      JS
    end

    def classify_provider_error(message)
      text = message.to_s.downcase

      if text.include?("2fa") || text.include?("aprobación") || text.include?("aprobacion")
        Error.new(message, :two_factor_timeout)
      elsif text.include?("clave") || text.include?("rut") || text.include?("login") || text.include?("credencial")
        AuthenticationError.new(message, :unauthorized)
      else
        Error.new(message.presence || "Unknown Santander scraper error", :scrape_failed)
      end
    end
end
