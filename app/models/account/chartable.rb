module Account::Chartable
  extend ActiveSupport::Concern

  def favorable_direction
    classification == "asset" ? "up" : "down"
  end

  def balance_series(period: Period.last_30_days, view: :balance, interval: nil)
    raise ArgumentError, "Invalid view type" unless [ :balance, :cash_balance, :holdings_balance ].include?(view.to_sym)

    @balance_series ||= {}

    memo_key = [ period.start_date, period.end_date, interval ].compact.join("_")

    builder = (@balance_series[memo_key] ||= Balance::ChartSeriesBuilder.new(
      account_ids: [ id ],
      currency: self.currency,
      period: period,
      favorable_direction: favorable_direction,
      interval: interval
    ))

    normalize_linked_investment_series(builder.send("#{view}_series"))
  end

  def sparkline_series
    cache_key = family.build_cache_key("#{id}_sparkline", invalidate_on_data_updates: true)

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      balance_series
    end
  end

  private
    def normalize_linked_investment_series(series)
      return series unless linked? && investment?
      return series if trades.exists?

      first_provider_holding_date = holdings.where.not(account_provider_id: nil).minimum(:date)
      return series unless first_provider_holding_date.present?

      trimmed_values = series.values.select { |value| value.date >= first_provider_holding_date }
      return series if trimmed_values.blank? || trimmed_values.length == series.values.length

      Series.new(
        start_date: trimmed_values.first.date,
        end_date: series.end_date,
        interval: series.interval,
        values: trimmed_values,
        favorable_direction: series.favorable_direction
      )
    end
end
