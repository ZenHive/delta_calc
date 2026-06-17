defmodule DeltaCalc.Carry do
  @moduledoc """
  Basis and funding carry math for spot/perp hedge profitability decisions.

  All inputs are caller-supplied values. This module performs no exchange access,
  persistence, or portfolio state lookup.
  """

  use Descripex, namespace: "/carry"

  @zero Decimal.new(0)
  @hundred Decimal.new(100)
  @days_per_year 365
  @default_periods_per_day 3
  @output_precision 8

  @type decimal_input :: Decimal.t() | number() | String.t()

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
          annualized_basis: Decimal.t(),
          basis_yield: Decimal.t(),
          funding_yield: Decimal.t(),
          net_yield: Decimal.t(),
          breakeven_funding: Decimal.t(),
          profitable?: boolean()
        }

  api(
    :annualized_basis,
    "Calculate spot/perp basis as an annualized percentage.",
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
    returns: %{type: :decimal, description: "Basis percentage, rounded to 8 places."}
  )

  @doc "Return `(perp_price - spot_price) / spot_price * 100`, or zero when spot is not positive."
  @spec annualized_basis(decimal_input(), decimal_input()) :: Decimal.t()
  def annualized_basis(spot_price, perp_price) do
    spot = to_decimal(spot_price)

    if Decimal.compare(spot, @zero) == :gt do
      perp_price
      |> to_decimal()
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

  @doc "Return the per-period funding rate that exactly offsets prorated basis yield."
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
          "Map with :spot_price, :perp_price, :funding_rate, optional :holding_days, and optional :periods_per_day.",
        schema: map()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with annualized_basis, basis_yield, funding_yield, net_yield, breakeven_funding, and profitable?."
    }
  )

  @doc "Return basis, funding, net yield, break-even rate, and profitability for a hedge."
  @spec net_carry(carry_params()) :: carry_result()
  def net_carry(params) do
    basis_yield = basis_yield(params)
    funding_yield = funding_yield(params)
    net_yield = quantize(Decimal.add(basis_yield, funding_yield))

    %{
      annualized_basis: annualized_basis(params.spot_price, params.perp_price),
      basis_yield: basis_yield,
      funding_yield: funding_yield,
      net_yield: net_yield,
      breakeven_funding: breakeven_funding(params),
      profitable?: Decimal.compare(net_yield, @zero) != :lt
    }
  end

  @spec basis_yield(carry_params()) :: Decimal.t()
  defp basis_yield(params) do
    params.spot_price
    |> annualized_basis(params.perp_price)
    |> period_yield(params)
  end

  @spec period_yield(Decimal.t(), carry_params()) :: Decimal.t()
  defp period_yield(annualized_yield, params) do
    holding_days = Map.get(params, :holding_days, @days_per_year)

    annualized_yield
    |> Decimal.mult(to_decimal(holding_days))
    |> Decimal.div(Decimal.new(@days_per_year))
    |> quantize()
  end

  @spec funding_yield(carry_params()) :: Decimal.t()
  defp funding_yield(params) do
    rate = params |> Map.fetch!(:funding_rate) |> to_decimal()
    periods = funding_periods(params)

    rate
    |> Decimal.mult(periods)
    |> Decimal.mult(@hundred)
    |> quantize()
  end

  @spec funding_periods(carry_params()) :: Decimal.t()
  defp funding_periods(params) do
    holding_days = params |> Map.get(:holding_days, @days_per_year) |> to_decimal()

    periods_per_day =
      params |> Map.get(:periods_per_day, @default_periods_per_day) |> to_decimal()

    Decimal.mult(holding_days, periods_per_day)
  end

  @spec quantize(Decimal.t()) :: Decimal.t()
  defp quantize(value), do: Decimal.round(value, @output_precision)

  @spec to_decimal(decimal_input()) :: Decimal.t()
  defp to_decimal(%Decimal{} = value), do: value

  defp to_decimal(value) do
    {:ok, decimal} = Decimal.cast(value)
    decimal
  end
end
