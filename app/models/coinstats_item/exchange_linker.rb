# frozen_string_literal: true

class CoinstatsItem::ExchangeLinker
  Result = Struct.new(:success?, :created_count, :errors, keyword_init: true)

  attr_reader :coinstats_item, :connection_id, :connection_fields, :name

  def initialize(coinstats_item, connection_id:, connection_fields:, name: nil)
    @coinstats_item = coinstats_item
    @connection_id = connection_id
    @connection_fields = connection_fields.to_h.compact_blank
    @name = name
  end

  def link
    return Result.new(success?: false, created_count: 0, errors: [ "Exchange is required" ]) if connection_id.blank?
    return Result.new(success?: false, created_count: 0, errors: [ "Exchange credentials are required" ]) if connection_fields.blank?

    exchange = fetch_exchange_definition
    validate_required_fields!(exchange)

    response = provider.connect_portfolio_exchange(
      connection_id: connection_id,
      connection_fields: connection_fields,
      name: name.presence || default_portfolio_name(exchange)
    )

    unless response.success?
      return Result.new(success?: false, created_count: 0, errors: [ response.error.message ])
    end

    payload = response.data.with_indifferent_access
    portfolio_id = payload[:portfolioId]
    raise Provider::Coinstats::Error, "CoinStats did not return a portfolioId" if portfolio_id.blank?

    coins = provider.list_portfolio_coins(portfolio_id: portfolio_id)

    created_count = 0

    ActiveRecord::Base.transaction do
      coinstats_item.update!(
        exchange_connection_id: connection_id,
        exchange_portfolio_id: portfolio_id,
        institution_id: connection_id,
        institution_name: exchange[:name],
        raw_institution_payload: exchange
      )

      Array(coins).each do |coin_data|
        next if zero_balance_coin?(coin_data)

        coinstats_account = upsert_exchange_account!(coin_data, exchange, portfolio_id)
        created_count += 1 if ensure_local_account!(coinstats_account)
      end
    end

    coinstats_item.sync_later

    Result.new(success?: true, created_count: created_count, errors: [])
  rescue Provider::Coinstats::Error, ArgumentError => e
    Result.new(success?: false, created_count: 0, errors: [ e.message ])
  end

  private

    def provider
      @provider ||= Provider::Coinstats.new(coinstats_item.api_key)
    end

    def fetch_exchange_definition
      exchange = provider.exchange_options.find { |option| option[:connection_id] == connection_id }
      raise ArgumentError, "Unsupported exchange connection: #{connection_id}" unless exchange

      exchange
    end

    def validate_required_fields!(exchange)
      missing_fields = Array(exchange[:connection_fields]).filter_map do |field|
        key = field[:key].to_s
        field[:name] if key.blank? || connection_fields[key].blank?
      end

      return if missing_fields.empty?

      raise ArgumentError, "Missing required exchange fields: #{missing_fields.join(', ')}"
    end

    def default_portfolio_name(exchange)
      "#{exchange[:name]} Portfolio"
    end

    def zero_balance_coin?(coin_data)
      amount = coin_data.with_indifferent_access[:count].to_d
      amount.zero?
    end

    def upsert_exchange_account!(coin_data, exchange, portfolio_id)
      coin_data = coin_data.with_indifferent_access
      coin = coin_data[:coin].to_h.with_indifferent_access
      coin_id = coin[:identifier].presence || coin_data[:coinId].presence || coin[:symbol].presence

      raise ArgumentError, "CoinStats portfolio coin is missing an identifier" if coin_id.blank?

      account_name = build_account_name(coin, exchange)
      current_balance = calculate_current_balance(coin_data)

      coinstats_account = coinstats_item.coinstats_accounts.find_or_initialize_by(
        account_id: coin_id.to_s,
        wallet_address: nil
      )

      coinstats_account.name = account_name
      coinstats_account.currency = "USD"
      coinstats_account.current_balance = current_balance
      coinstats_account.provider = exchange[:name]
      coinstats_account.account_status = "active"
      coinstats_account.institution_metadata = {
        logo: coin[:icon],
        exchange_logo: exchange[:icon]
      }.compact
      coinstats_account.raw_payload = build_snapshot(coin_data, coin, exchange, portfolio_id, current_balance)
      coinstats_account.save!
      coinstats_account
    end

    def ensure_local_account!(coinstats_account)
      return false if coinstats_account.account.present?

      account = Account.create_and_sync(
        family: coinstats_item.family,
        name: coinstats_account.name,
        balance: coinstats_account.current_balance || 0,
        cash_balance: coinstats_account.current_balance || 0,
        currency: coinstats_account.currency || "USD",
        accountable_type: "Crypto",
        accountable_attributes: {
          subtype: "exchange",
          tax_treatment: "taxable"
        },
        skip_initial_sync: true
      )

      AccountProvider.create!(account: account, provider: coinstats_account)
      true
    end

    def build_account_name(coin, exchange)
      coin_name = coin[:name].presence || coin[:symbol].presence || coin[:identifier].to_s.titleize
      "#{coin_name} (#{exchange[:name]})"
    end

    def calculate_current_balance(coin_data)
      coin_data = coin_data.with_indifferent_access
      amount = coin_data[:count].to_d
      price_usd = coin_data.dig(:price, :USD).to_d
      total_worth = coin_data.dig(:coinData, :currentValue).to_d

      return total_worth if total_worth.nonzero?

      amount * price_usd
    end

    def build_snapshot(coin_data, coin, exchange, portfolio_id, current_balance)
      coin_data.to_h.merge(
        source: "exchange",
        portfolio_id: portfolio_id,
        connection_id: exchange[:connection_id],
        exchange_name: exchange[:name],
        id: coin[:identifier].presence || coin[:symbol],
        name: build_account_name(coin, exchange),
        balance: current_balance,
        currency: "USD",
        institution_logo: coin[:icon]
      )
    end
end
