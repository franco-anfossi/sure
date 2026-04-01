# frozen_string_literal: true

require "test_helper"

class SantanderChileAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    # TODO: Create or reference your santander_chile_item fixture
    # @santander_chile_item = santander_chile_items(:configured_item)
    # @santander_chile_account = santander_chile_accounts(:test_account)

    # Create a linked Sure account for the provider account
    @account = @family.accounts.create!(
      name: "Test Account",
      balance: 10000,
      currency: "USD",
      accountable: Depository.new
    )

    # TODO: Link the provider account to the Sure account
    # @santander_chile_account.ensure_account_provider!(@account)
    # @santander_chile_account.reload
  end

  # ==========================================================================
  # Processor tests
  # ==========================================================================

  test "processor initializes with santander_chile_account" do
    skip "TODO: Set up santander_chile_account fixture"

    # processor = SantanderChileAccount::Processor.new(@santander_chile_account)
    # assert_not_nil processor
  end

  test "processor skips processing when no linked account" do
    skip "TODO: Set up santander_chile_account fixture"

    # Remove the account provider link
    # @santander_chile_account.account_provider&.destroy
    # @santander_chile_account.reload

    # processor = SantanderChileAccount::Processor.new(@santander_chile_account)
    # assert_nothing_raised { processor.process }
  end

  test "processor updates account balance" do
    skip "TODO: Set up santander_chile_account fixture"

    # @santander_chile_account.update!(current_balance: 15000)
    #
    # processor = SantanderChileAccount::Processor.new(@santander_chile_account)
    # processor.process
    #
    # @account.reload
    # assert_equal 15000, @account.balance.to_f
  end

  # ==========================================================================
  # TransactionsProcessor tests
  # ==========================================================================

  test "transactions processor creates entries from raw payload" do
    skip "TODO: Set up santander_chile_account fixture and transactions payload"

    # @santander_chile_account.update!(raw_transactions_payload: [
    #   {
    #     "id" => "txn_001",
    #     "amount" => 50.00,
    #     "date" => Date.current.to_s,
    #     "name" => "Coffee Shop",
    #     "pending" => false
    #   }
    # ])
    #
    # processor = SantanderChileAccount::Transactions::Processor.new(@santander_chile_account)
    # result = processor.process
    #
    # assert result[:success]
    # assert_equal 1, result[:imported]
  end

  test "transactions processor handles missing transaction id gracefully" do
    skip "TODO: Set up santander_chile_account fixture"

    # @santander_chile_account.update!(raw_transactions_payload: [
    #   { "id" => nil, "amount" => 50.00, "date" => Date.current.to_s }
    # ])
    #
    # processor = SantanderChileAccount::Transactions::Processor.new(@santander_chile_account)
    # result = processor.process
    #
    # assert_equal 1, result[:failed]
  end

  test "transactions processor returns empty result when no transactions" do
    skip "TODO: Set up santander_chile_account fixture"

    # @santander_chile_account.update!(raw_transactions_payload: [])
    #
    # processor = SantanderChileAccount::Transactions::Processor.new(@santander_chile_account)
    # result = processor.process
    #
    # assert result[:success]
    # assert_equal 0, result[:total]
  end
end
