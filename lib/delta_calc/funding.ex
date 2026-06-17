defmodule DeltaCalc.Funding do
  @moduledoc """
  Pure funding-rate math: APR annualisation, cross-venue comparison, arbitrage
  detection, and trend analysis.

  All functions take caller-supplied `Decimal` rates — no exchange clients or I/O.
  """

  use Descripex, namespace: "/funding"

  @arbitrage_threshold Decimal.new("0.0005")
  @trend_threshold Decimal.new("0.00001")
  @default_period_hours 8
  @days_per_year 365
  @hundred Decimal.new(100)

  @typedoc "Annualised funding-rate breakdown as percentage Decimals."
  @type apr_result :: %{
          hourly: Decimal.t(),
          daily: Decimal.t(),
          annual: Decimal.t()
        }

  @typedoc "Per-symbol cross-venue funding comparison."
  @type comparison_result :: %{
          optional(:insufficient_data) => true,
          optional(:arbitrage_opportunity) => boolean(),
          optional(:delta) => Decimal.t(),
          optional(:max_exchange) => atom(),
          optional(:min_exchange) => atom(),
          optional(:annual_apr_delta) => Decimal.t(),
          optional(:ranked) => [{atom(), Decimal.t()}]
        }

  @typedoc "Funding trend summary from a rate series."
  @type trend_result :: %{
          avg_rate: Decimal.t(),
          max_rate: Decimal.t(),
          min_rate: Decimal.t(),
          trend: :increasing | :decreasing | :flat,
          slope: Decimal.t(),
          volatility: Decimal.t(),
          data_points: non_neg_integer()
        }

  api(
    :funding_apr,
    "Annualise a per-period funding rate into hourly, daily, and annual percentages.",
    params: [
      rate: [
        kind: :value,
        description: "Per-period funding rate as a decimal fraction (e.g. 0.0001 for 0.01%).",
        schema: float()
      ],
      period_hours: [
        kind: :value,
        default: 8,
        description: "Hours between funding settlements.",
        schema: pos_integer()
      ]
    ],
    returns: %{
      type: :tagged_tuple,
      description:
        "{:ok, %{hourly, daily, annual}} as percentage Decimals, or {:error, :invalid_rate}."
    }
  )

  @doc "Convert a per-period funding rate into hourly, daily, and annual percentage APR."
  @spec funding_apr(Decimal.t() | number(), pos_integer()) ::
          {:ok, apr_result()} | {:error, :invalid_rate}
  def funding_apr(rate, period_hours \\ @default_period_hours) do
    with {:ok, rate_dec} <- cast_rate(rate),
         true <- period_hours > 0 do
      period = Decimal.new(period_hours)
      funding_per_day = Decimal.div(Decimal.new(24), period)

      hourly_rate = Decimal.div(rate_dec, period)
      daily_rate = Decimal.mult(rate_dec, funding_per_day)
      annual_rate = Decimal.mult(daily_rate, Decimal.new(@days_per_year))

      {:ok,
       %{
         hourly: pct(hourly_rate, 4),
         daily: pct(daily_rate, 4),
         annual: pct(annual_rate, 2)
       }}
    else
      _ -> {:error, :invalid_rate}
    end
  end

  api(
    :compare_funding_rates,
    "Compare venue funding rates for one or more symbols and rank venues by rate.",
    params: [
      rates: [
        kind: :value,
        description:
          "Single symbol: %{venue => rate}. Multiple symbols: %{\"SYMBOL\" => %{venue => rate}}.",
        schema: map()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Per-symbol comparison with venue rates, delta, arbitrage flag, and :ranked venue list."
    }
  )

  @doc """
  Compare funding rates across venues.

  Pass `%{binance: rate, bybit: rate}` for one symbol, or
  `%{"BTCUSDT" => %{binance: rate, bybit: rate}}` for many.
  """
  @spec compare_funding_rates(map()) :: map() | comparison_result()
  def compare_funding_rates(rates) when is_map(rates) do
    if multi_symbol?(rates) do
      Map.new(rates, fn {symbol, venue_rates} ->
        {symbol, compare_single_symbol(venue_rates)}
      end)
    else
      compare_single_symbol(rates)
    end
  end

  api(
    :find_arbitrage_opportunities,
    "Find cross-venue funding spreads that exceed a minimum delta threshold.",
    params: [
      comparison: [
        kind: :value,
        description: "Output of compare_funding_rates/1 (single- or multi-symbol).",
        schema: map()
      ],
      min_delta: [
        kind: :value,
        default: 0.001,
        description: "Minimum absolute rate spread to include.",
        schema: float()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "List of opportunity maps sorted by annual APR delta descending " <>
          "(:symbol, :long_exchange, :short_exchange, :delta, :annual_apr_delta, :rates)."
    }
  )

  @doc "Return arbitrage opportunities from a comparison map, filtered by `min_delta`."
  @spec find_arbitrage_opportunities(map(), Decimal.t() | number()) :: [map()]
  def find_arbitrage_opportunities(comparison, min_delta \\ Decimal.new("0.001")) do
    min_delta = ensure_decimal(min_delta)

    comparison
    |> normalize_comparison_entries()
    |> Enum.filter(fn {_symbol, data} ->
      delta = Map.get(data, :delta, Decimal.new(0))

      Map.get(data, :arbitrage_opportunity, false) and
        Decimal.compare(Decimal.abs(delta), min_delta) != :lt
    end)
    |> Enum.map(fn {symbol, data} -> build_opportunity(symbol, data) end)
    |> Enum.sort_by(& &1.annual_apr_delta, :desc)
  end

  api(
    :funding_trend,
    "Analyse a funding-rate time series for direction, slope, and volatility.",
    params: [
      series: [
        kind: :value,
        description: "List of rates (Decimal/number) or maps with a :rate key."
      ]
    ],
    returns: %{
      type: :tagged_tuple,
      description:
        "{:ok, %{avg_rate, max_rate, min_rate, trend, slope, volatility, data_points}} " <>
          "or {:error, :insufficient_data}."
    }
  )

  @doc "Summarise a funding-rate series with trend direction and half-series slope."
  @spec funding_trend(list()) :: {:ok, trend_result()} | {:error, :insufficient_data}
  def funding_trend(series) when is_list(series) and series != [] do
    rates = Enum.map(series, &extract_rate/1)
    data_points = length(rates)

    sum = Enum.reduce(rates, Decimal.new(0), &Decimal.add/2)
    count = Decimal.new(data_points)
    avg_rate = Decimal.div(sum, count)

    max_rate = Enum.max_by(rates, &Decimal.to_float/1)
    min_rate = Enum.min_by(rates, &Decimal.to_float/1)
    {trend, slope} = trend_and_slope(rates)

    {:ok,
     %{
       avg_rate: Decimal.round(avg_rate, 6),
       max_rate: Decimal.round(max_rate, 6),
       min_rate: Decimal.round(min_rate, 6),
       trend: trend,
       slope: Decimal.round(slope, 8),
       volatility: Decimal.round(Decimal.sub(max_rate, min_rate), 6),
       data_points: data_points
     }}
  end

  def funding_trend(_), do: {:error, :insufficient_data}

  @spec compare_single_symbol(map()) :: comparison_result()
  defp compare_single_symbol(rates) when map_size(rates) < 2 do
    %{
      insufficient_data: true,
      arbitrage_opportunity: false,
      ranked: rank_venues(rates)
    }
  end

  defp compare_single_symbol(rates) do
    decimal_rates = Map.new(rates, fn {venue, rate} -> {venue, ensure_decimal(rate)} end)
    rate_values = Map.values(decimal_rates)

    max_rate = Enum.max_by(rate_values, &Decimal.to_float/1)
    min_rate = Enum.min_by(rate_values, &Decimal.to_float/1)
    delta = Decimal.sub(max_rate, min_rate)

    {max_exchange, _} = Enum.find(decimal_rates, fn {_, r} -> Decimal.equal?(r, max_rate) end)
    {min_exchange, _} = Enum.find(decimal_rates, fn {_, r} -> Decimal.equal?(r, min_rate) end)

    arbitrage? = Decimal.compare(Decimal.abs(delta), @arbitrage_threshold) == :gt

    base =
      decimal_rates
      |> Map.merge(%{
        delta: Decimal.round(delta, 6),
        max_exchange: max_exchange,
        min_exchange: min_exchange,
        arbitrage_opportunity: arbitrage?,
        ranked: rank_venues(decimal_rates)
      })

    if arbitrage? do
      annual_apr_delta =
        delta
        |> Decimal.mult(Decimal.new(3))
        |> Decimal.mult(Decimal.new(@days_per_year))
        |> Decimal.mult(@hundred)
        |> Decimal.round(2)

      Map.put(base, :annual_apr_delta, annual_apr_delta)
    else
      base
    end
  end

  @spec rank_venues(map()) :: [{atom(), Decimal.t()}]
  defp rank_venues(rates) do
    rates
    |> Enum.map(fn {venue, rate} -> {venue, ensure_decimal(rate)} end)
    |> Enum.sort_by(fn {_venue, rate} -> Decimal.to_float(rate) end, :desc)
  end

  @spec build_opportunity(String.t() | atom(), map()) :: map()
  defp build_opportunity(symbol, data) do
    venue_rates =
      data
      |> Map.drop([
        :delta,
        :max_exchange,
        :min_exchange,
        :arbitrage_opportunity,
        :annual_apr_delta,
        :insufficient_data,
        :ranked
      ])

    %{
      symbol: symbol,
      long_exchange: data.min_exchange,
      short_exchange: data.max_exchange,
      delta: data.delta,
      annual_apr_delta: Map.get(data, :annual_apr_delta, Decimal.new(0)),
      rates: venue_rates
    }
  end

  @spec normalize_comparison_entries(map()) :: [{String.t() | atom(), map()}]
  defp normalize_comparison_entries(comparison) do
    if multi_symbol?(comparison) do
      Map.to_list(comparison)
    else
      [{:unknown, comparison}]
    end
  end

  @spec multi_symbol?(map()) :: boolean()
  defp multi_symbol?(map) do
    map != %{} and Enum.all?(map, fn {key, value} -> is_binary(key) and is_map(value) end)
  end

  @spec trend_and_slope([Decimal.t()]) :: {:increasing | :decreasing | :flat, Decimal.t()}
  defp trend_and_slope([_single]), do: {:flat, Decimal.new(0)}

  defp trend_and_slope(rates) do
    mid = div(length(rates), 2)
    {first_half, second_half} = Enum.split(rates, mid)

    first_avg = avg(first_half)
    second_avg = avg(second_half)
    slope = Decimal.sub(second_avg, first_avg)

    trend =
      cond do
        Decimal.compare(slope, @trend_threshold) == :gt -> :increasing
        Decimal.compare(slope, Decimal.negate(@trend_threshold)) == :lt -> :decreasing
        true -> :flat
      end

    {trend, slope}
  end

  @spec avg([Decimal.t()]) :: Decimal.t()
  defp avg(values) do
    sum = Enum.reduce(values, Decimal.new(0), &Decimal.add/2)
    Decimal.div(sum, Decimal.new(length(values)))
  end

  @spec extract_rate(term()) :: Decimal.t()
  defp extract_rate(%{rate: rate}), do: ensure_decimal(rate)
  defp extract_rate(rate), do: ensure_decimal(rate)

  @spec pct(Decimal.t(), non_neg_integer()) :: Decimal.t()
  defp pct(rate, precision), do: rate |> Decimal.mult(@hundred) |> Decimal.round(precision)

  @spec cast_rate(term()) :: {:ok, Decimal.t()} | {:error, :invalid_rate}
  defp cast_rate(%Decimal{} = rate), do: {:ok, rate}
  defp cast_rate(rate) when is_integer(rate), do: {:ok, Decimal.new(rate)}
  defp cast_rate(rate) when is_float(rate), do: {:ok, Decimal.from_float(rate)}

  defp cast_rate(rate) when is_binary(rate) do
    case Decimal.parse(rate) do
      {decimal, _} -> {:ok, decimal}
      :error -> {:error, :invalid_rate}
    end
  end

  defp cast_rate(_), do: {:error, :invalid_rate}

  @spec ensure_decimal(term()) :: Decimal.t()
  defp ensure_decimal(%Decimal{} = value), do: value
  defp ensure_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp ensure_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp ensure_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> Decimal.new(0)
    end
  end

  defp ensure_decimal(_), do: Decimal.new(0)
end
