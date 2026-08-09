defmodule DeltaCalc.Carry do
  @moduledoc """
  Basis and funding carry math for spot/perp hedge profitability decisions.

  Yield semantics:
  - `basis/2` is an instantaneous premium or discount (stock): `(perp - spot) / spot * 100`.
  - `basis_yield/1` (private) is the one-time basis capture over the hold — equal to `basis/2`
    at entry, not time-prorated.
  - `funding_yield/1` sums per-period funding rates over `holding_days` (flow).

  `net_yield` adds the one-time basis stock to accumulated funding flow so both terms are
  percentages over the same holding window.

  All inputs are caller-supplied values. This module performs no exchange access,
  persistence, or portfolio state lookup.
  """

  use Descripex, namespace: "/carry"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)
  @hundred Decimal.new(100)
  @days_per_year 365
  @default_periods_per_day 3
  @output_precision 8

  @type decimal_input :: DecimalInput.input()

  @typedoc "Inputs shared by carry calculations."
  @type carry_params :: %{
          required(:spot_price) => decimal_input(),
          required(:perp_price) => decimal_input(),
          optional(:funding_rate) => decimal_input(),
          optional(:holding_days) => pos_integer() | Decimal.t(),
          optional(:periods_per_day) => pos_integer() | Decimal.t()
        }

  @typedoc "Net carry decision output as percentage yields."
  @type carry_result :: %{
          basis: Decimal.t(),
          basis_yield: Decimal.t(),
          funding_yield: Decimal.t(),
          net_yield: Decimal.t(),
          breakeven_funding: Decimal.t(),
          profitable?: boolean()
        }

  api(
    :basis,
    "Calculate spot/perp basis as an instantaneous percentage premium or discount.",
    params: [
      spot_price: [
        kind: :value,
        description: "Spot market price.",
        schema: float()
      ],
      perp_price: [
        kind: :value,
        description: "Perpetual or futures price.",
        schema: float()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "(perp - spot) / spot * 100, rounded to 8 places. Not annualized."
    }
  )

  @doc "Return `(perp_price - spot_price) / spot_price * 100`, or zero when spot is not positive."
  @spec basis(decimal_input(), decimal_input()) :: Decimal.t()
  def basis(spot_price, perp_price) do
    spot = DecimalInput.cast!(spot_price)

    if Decimal.compare(spot, @zero) == :gt do
      perp_price
      |> DecimalInput.cast!()
      |> Decimal.sub(spot)
      |> Decimal.div(spot)
      |> Decimal.mult(@hundred)
      |> quantize()
    else
      @zero
    end
  end

  api(
    :breakeven_funding,
    "Calculate the per-period funding rate where basis-adjusted carry is zero.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :spot_price, :perp_price, optional :holding_days, and optional :periods_per_day.",
        schema: map()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Per-period funding rate as a decimal fraction, rounded to 8 places."
    }
  )

  @doc "Return the per-period funding rate that exactly offsets basis yield over the hold."
  @spec breakeven_funding(carry_params()) :: Decimal.t()
  def breakeven_funding(params) do
    periods = funding_periods(params)

    if Decimal.compare(periods, @zero) == :gt do
      params
      |> basis_yield()
      |> Decimal.negate()
      |> Decimal.div(periods)
      |> Decimal.div(@hundred)
      |> quantize()
    else
      @zero
    end
  end

  api(
    :net_carry,
    "Combine funding income or cost with basis yield over a holding period.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :spot_price, :perp_price, :funding_rate as a per-period decimal fraction " <>
            "(e.g. 0.0001 for 0.01%), optional :holding_days, and optional :periods_per_day.",
        schema: map()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with basis, basis_yield, funding_yield, net_yield, breakeven_funding, and profitable?."
    }
  )

  @doc "Return basis, funding, net yield, break-even rate, and profitability for a hedge."
  @spec net_carry(carry_params()) :: carry_result()
  def net_carry(params) do
    basis_yield = basis_yield(params)
    funding_yield = funding_yield(params)
    net_yield = quantize(Decimal.add(basis_yield, funding_yield))

    %{
      basis: basis(params.spot_price, params.perp_price),
      basis_yield: basis_yield,
      funding_yield: funding_yield,
      net_yield: net_yield,
      breakeven_funding: breakeven_funding(params),
      profitable?: Decimal.compare(net_yield, @zero) != :lt
    }
  end

  @spec basis_yield(carry_params()) :: Decimal.t()
  defp basis_yield(params) do
    basis(params.spot_price, params.perp_price)
  end

  @spec funding_yield(carry_params()) :: Decimal.t()
  defp funding_yield(params) do
    rate = params |> Map.fetch!(:funding_rate) |> DecimalInput.cast!()
    periods = funding_periods(params)

    rate
    |> Decimal.mult(periods)
    |> Decimal.mult(@hundred)
    |> quantize()
  end

  @spec funding_periods(carry_params()) :: Decimal.t()
  defp funding_periods(params) do
    holding_days = params |> Map.get(:holding_days, @days_per_year) |> DecimalInput.cast!()

    periods_per_day =
      params |> Map.get(:periods_per_day, @default_periods_per_day) |> DecimalInput.cast!()

    Decimal.mult(holding_days, periods_per_day)
  end

  @spec quantize(Decimal.t()) :: Decimal.t()
  defp quantize(value), do: Decimal.round(value, @output_precision)
end
