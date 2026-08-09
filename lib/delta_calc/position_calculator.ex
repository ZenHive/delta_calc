defmodule DeltaCalc.PositionCalculator do
  @moduledoc """
  Core position sizing calculations for risk management and leverage planning.

  Handles position size, effective leverage, safety analysis, allocation breakdowns,
  and liquidation price analysis using Decimal arithmetic throughout.
  """

  use Descripex, namespace: "/position_calculator"

  alias DeltaCalc.Calc

  @default_one Decimal.new("1")
  @default_hundred Decimal.new("100")

  @type params :: %{
          aum: Decimal.t(),
          side: :long | :short,
          entry_price: Decimal.t(),
          subaccount_allocation: Decimal.t(),
          initial_position_pct: Decimal.t(),
          black_swan_pct: Decimal.t(),
          ui_leverage: Decimal.t(),
          mmr_rate: Decimal.t(),
          mark_buffer: Decimal.t()
        }

  @type calculation_result :: %{
          allocation: map(),
          position: map(),
          effective_leverage: Decimal.t(),
          leverage_to_aum: Decimal.t(),
          safety: map(),
          mmr_info: map()
        }

  api(:calculate_position, "Compute position size, leverage, safety, and allocation breakdown.",
    params: [
      params: [
        kind: :value,
        description:
          "Position inputs: aum, side, entry_price, subaccount_allocation, initial_position_pct, black_swan_pct, ui_leverage, mmr_rate, mark_buffer"
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with allocation, position, effective_leverage, leverage_to_aum, safety, and mmr_info, or {:error, reason}"
    }
  )

  @doc """
  Performs comprehensive position calculations based on validated parameters.

  ## Parameters
  - `params`: Map containing validated parameters including:
    - `:aum` - Assets Under Management (Decimal)
    - `:side` - Position side atom (:long, :short)
    - `:entry_price` - Entry price (Decimal)
    - `:subaccount_allocation` - Subaccount allocation amount (Decimal)
    - `:initial_position_pct` - Initial position percentage as decimal (0-1)
    - `:black_swan_pct` - Black swan threshold as decimal (0-1)
    - `:ui_leverage` - UI leverage setting (Decimal)
    - `:mmr_rate` - Minimum margin requirement rate (Decimal)
    - `:mark_buffer` - Mark price buffer (Decimal)

  ## Returns
  A map containing:
  - `:allocation` - Allocation breakdown with subaccount equity, position, and reserves
  - `:position` - Position details with notional value and effective leverage
  - `:effective_leverage` - Overall effective leverage
  - `:leverage_to_aum` - Position size as percentage of total AUM
  - `:safety` - Safety analysis with liquidation and black swan metrics
  - `:mmr_info` - MMR rate information for display

  ## Examples

      params = %{
        aum: Decimal.new("10000"),
        side: :long,
        entry_price: Decimal.new("3000"),
        subaccount_allocation: Decimal.new("100"),
        initial_position_pct: Decimal.new("0.5"),
        black_swan_pct: Decimal.new("0.15"),
        ui_leverage: Decimal.new("2"),
        mmr_rate: Decimal.new("0.005"),
        mark_buffer: Decimal.new("0.001")
      }

      calculate_position(params)
  """
  @spec calculate_position(params()) :: calculation_result() | {:error, atom()}
  def calculate_position(params) do
    %{
      aum: _aum,
      side: side,
      entry_price: entry_price,
      subaccount_allocation: subaccount_allocation,
      initial_position_pct: initial_position_pct,
      black_swan_pct: black_swan_pct,
      ui_leverage: ui_leverage,
      mmr_rate: mmr_rate,
      mark_buffer: mark_buffer
    } = params

    subaccount_equity = subaccount_allocation
    initial_position_allocation = Decimal.mult(subaccount_equity, initial_position_pct)
    position_size = Decimal.mult(initial_position_allocation, ui_leverage)
    dca_reserve = Decimal.sub(subaccount_equity, initial_position_allocation)
    mmr_total = Decimal.add(mmr_rate, mark_buffer)

    with %Decimal{} = effective_leverage <-
           Calc.effective_leverage(position_size, subaccount_equity),
         %Decimal{} = leverage_to_aum <- Calc.leverage_to_aum(position_size, params.aum),
         %Decimal{} = liquidation_price <-
           Calc.liquidation(entry_price, effective_leverage, mmr_total, side) do
      black_swan_price = calculate_black_swan_price(entry_price, black_swan_pct, side)
      is_safe = check_black_swan_safety(liquidation_price, black_swan_price, side)
      distance_to_liq = calculate_liquidation_distance(entry_price, liquidation_price, side)
      leftover = calculate_leftover(params.aum, subaccount_equity)

      %{
        allocation:
          build_allocation_result(
            subaccount_equity,
            initial_position_allocation,
            dca_reserve,
            initial_position_pct,
            leftover
          ),
        position: build_position_result(position_size, effective_leverage, entry_price, side),
        effective_leverage: Calc.quantize(effective_leverage),
        leverage_to_aum: Calc.quantize(leverage_to_aum),
        safety:
          build_safety_result(
            is_safe,
            liquidation_price,
            black_swan_price,
            distance_to_liq,
            black_swan_pct
          ),
        mmr_info: build_mmr_info(mmr_rate)
      }
    end
  end

  @spec calculate_leftover(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_leftover(total_aum, subaccount_equity) do
    Decimal.sub(total_aum, subaccount_equity)
  end

  @spec calculate_black_swan_price(Decimal.t(), Decimal.t(), :long | :short) :: Decimal.t()
  defp calculate_black_swan_price(entry_price, black_swan_pct, side) do
    if side == :long do
      Decimal.mult(entry_price, Decimal.sub(@default_one, black_swan_pct))
    else
      Decimal.mult(entry_price, Decimal.add(@default_one, black_swan_pct))
    end
  end

  @spec check_black_swan_safety(Decimal.t(), Decimal.t(), :long | :short) :: boolean()
  defp check_black_swan_safety(liquidation_price, black_swan_price, side) do
    if side == :long do
      Decimal.compare(liquidation_price, black_swan_price) == :lt
    else
      Decimal.compare(liquidation_price, black_swan_price) == :gt
    end
  end

  @spec calculate_liquidation_distance(Decimal.t(), Decimal.t(), :long | :short) :: Decimal.t()
  defp calculate_liquidation_distance(entry_price, liquidation_price, side) do
    if side == :long do
      Decimal.div(
        Decimal.sub(entry_price, liquidation_price),
        entry_price
      )
    else
      Decimal.div(
        Decimal.sub(liquidation_price, entry_price),
        entry_price
      )
    end
  end

  @spec build_allocation_result(
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t()
        ) :: map()
  defp build_allocation_result(
         subaccount_equity,
         initial_position_allocation,
         dca_reserve,
         initial_position_pct,
         leftover
       ) do
    %{
      sub_eq: Calc.quantize(subaccount_equity),
      init_position: Calc.quantize(initial_position_allocation),
      reserve: Calc.quantize(dca_reserve),
      reserve_pct:
        Calc.quantize(
          Decimal.mult(Decimal.sub(@default_one, initial_position_pct), @default_hundred)
        ),
      leftover: Calc.quantize(leftover)
    }
  end

  @spec build_position_result(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: map()
  defp build_position_result(position_size, effective_leverage, entry_price, side) do
    position = %{
      notional: Calc.quantize(position_size),
      eff_lev: Calc.quantize(effective_leverage)
    }

    if side == :long do
      tokens = Decimal.div(position_size, entry_price)
      Map.put(position, :tokens, Calc.quantize(tokens))
    else
      position
    end
  end

  @spec build_safety_result(
          boolean(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t()
        ) :: map()
  defp build_safety_result(
         is_safe,
         liquidation_price,
         black_swan_price,
         distance_to_liq,
         black_swan_pct
       ) do
    %{
      is_safe: is_safe,
      liquidation_price: Calc.quantize(liquidation_price),
      black_swan_price: Calc.quantize(black_swan_price),
      distance_to_liq_pct: Calc.quantize(Decimal.mult(distance_to_liq, @default_hundred)),
      black_swan_pct: Decimal.mult(black_swan_pct, @default_hundred)
    }
  end

  @spec build_mmr_info(Decimal.t()) :: map()
  defp build_mmr_info(mmr_rate) do
    %{
      mmr: Calc.quantize(mmr_rate),
      rate_display: Calc.quantize(Decimal.mult(mmr_rate, @default_hundred))
    }
  end
end
