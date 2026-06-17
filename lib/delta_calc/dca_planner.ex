defmodule DeltaCalc.DCAPlanner do
  @moduledoc """
  DCA ladder planning and strategy management.

  Builds defensive and aggressive DCA presets, enhances ladder steps with portfolio
  metrics, and orchestrates full ladder calculations via `DeltaCalc.Calc`.
  """

  use Descripex, namespace: "/dca_planner"

  alias DeltaCalc.Calc
  alias DeltaCalc.Presets

  @default_zero Decimal.new("0")
  @default_one Decimal.new("1")
  @default_hundred Decimal.new("100")

  @type dca_preset :: [{Decimal.t(), Decimal.t()}]
  @type dca_step :: map()
  @type dca_result :: %{
          optional(:defensive) => map(),
          optional(:aggressive) => map()
        }

  @type dca_params :: %{
          params: map(),
          position_with_tokens: map(),
          dca_reserve: Decimal.t(),
          entry_price: Decimal.t(),
          ui_leverage: Decimal.t(),
          side: :long | :short,
          mmr_rate: Decimal.t(),
          mark_buffer: Decimal.t(),
          aum: Decimal.t(),
          black_swan_pct: Decimal.t()
        }

  api(
    :calculate_dca_ladder,
    "Calculate defensive and aggressive DCA ladder results when reserve is available.",
    params: [
      dca_params: [
        kind: :value,
        description:
          "Map with params, position_with_tokens, dca_reserve, entry_price, ui_leverage, side, mmr_rate, mark_buffer, aum, black_swan_pct"
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :defensive and :aggressive strategy results (enhanced steps), or nil when DCA disabled or no reserve"
    }
  )

  @doc """
  Calculates DCA ladder results if reserve is available and DCA is enabled.

  Builds both defensive and aggressive DCA strategies and calculates complete
  ladder results with enhanced step information including safety metrics.

  ## Parameters
  - `dca_params`: Map or struct containing all DCA parameters:
    - `params`: Validated parameters map containing DCA configuration
    - `position_with_tokens`: Position map with tokens calculation
    - `dca_reserve`: Available DCA reserve amount (Decimal)
    - `entry_price`: Entry price for the position (Decimal)
    - `ui_leverage`: UI leverage setting (Decimal)
    - `side`: Position side (:long or :short)
    - `mmr_rate`: Minimum margin requirement rate (Decimal)
    - `mark_buffer`: Mark price buffer (Decimal)
    - `aum`: Total Assets Under Management (Decimal)
    - `black_swan_pct`: Black swan threshold as decimal (0-1)

  ## Returns
  Map with DCA ladder results, or `nil` if no DCA available:
  - `:defensive` - Defensive DCA strategy results (if available)
  - `:aggressive` - Aggressive DCA strategy results (if available)

  Each strategy contains:
  - `:steps` - List of enhanced DCA steps with safety metrics
  - Other fields from `Calc.dca_ladder/8` result

  ## Examples

      dca_params = %{
        params: %{
          dca_enabled: true,
          defensive_prices: [Decimal.new("2850"), Decimal.new("2700")],
          dca_allocations: [Decimal.new("30"), Decimal.new("30")]
        },
        position_with_tokens: position,
        dca_reserve: reserve,
        entry_price: entry,
        ui_leverage: leverage,
        side: :long,
        mmr_rate: mmr,
        mark_buffer: buffer,
        aum: aum,
        black_swan_pct: swan_pct
      }

      calculate_dca_ladder(dca_params)
      #=> %{
      #     defensive: %{steps: [...], final_avg_entry: ...},
      #     aggressive: %{steps: [...], final_avg_entry: ...}
      #   }
  """
  @spec calculate_dca_ladder(dca_params()) :: dca_result() | nil
  def calculate_dca_ladder(dca_params) do
    do_calculate_dca_ladder(dca_params)
  end

  @doc """
  Calculates DCA ladder results with individual parameters (backward compatibility).

  This function maintains backward compatibility by accepting individual parameters
  and internally constructing the dca_params map.

  See `calculate_dca_ladder/1` for full documentation.
  """
  @spec calculate_dca_ladder(
          map(),
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          :long | :short,
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t()
        ) :: dca_result() | nil
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def calculate_dca_ladder(
        params,
        position_with_tokens,
        dca_reserve,
        entry_price,
        ui_leverage,
        side,
        mmr_rate,
        mark_buffer,
        aum,
        black_swan_pct
      ) do
    calculate_dca_ladder(
      build_dca_params(
        params,
        position_with_tokens,
        dca_reserve,
        entry_price,
        ui_leverage,
        side,
        mmr_rate,
        mark_buffer,
        aum,
        black_swan_pct
      )
    )
  end

  @spec do_calculate_dca_ladder(dca_params()) :: dca_result() | nil
  defp do_calculate_dca_ladder(dca_params) do
    if Decimal.compare(dca_params.dca_reserve, @default_zero) == :gt and
         Map.get(dca_params.params, :dca_enabled, true) do
      defensive_preset =
        build_defensive_preset(dca_params.params, dca_params.entry_price, dca_params.side)

      aggressive_preset =
        build_aggressive_preset(dca_params.params, dca_params.entry_price, dca_params.side)

      defensive_result =
        Calc.dca_ladder(
          dca_params.position_with_tokens,
          dca_params.dca_reserve,
          dca_params.entry_price,
          dca_params.ui_leverage,
          defensive_preset,
          dca_params.side,
          dca_params.mmr_rate,
          dca_params.mark_buffer
        )

      aggressive_result =
        Calc.dca_ladder(
          dca_params.position_with_tokens,
          dca_params.dca_reserve,
          dca_params.entry_price,
          dca_params.ui_leverage,
          aggressive_preset,
          dca_params.side,
          dca_params.mmr_rate,
          dca_params.mark_buffer
        )

      build_strategy_results(
        defensive_result,
        aggressive_result,
        dca_params.aum,
        dca_params.black_swan_pct,
        dca_params.entry_price,
        dca_params.side
      )
    end
  end

  defp build_strategy_results(
         defensive_result,
         aggressive_result,
         aum,
         black_swan_pct,
         entry_price,
         side
       ) do
    %{
      defensive:
        enhance_dca_result(
          defensive_result,
          aum,
          black_swan_pct,
          entry_price,
          side
        ),
      aggressive:
        enhance_dca_result(
          aggressive_result,
          aum,
          black_swan_pct,
          entry_price,
          side
        )
    }
  end

  defp enhance_dca_result(dca_result, aum, black_swan_pct, entry_price, side) do
    %{
      dca_result
      | steps:
          enhance_dca_steps(
            dca_result.steps,
            aum,
            black_swan_pct,
            entry_price,
            side
          )
    }
  end

  api(:build_defensive_preset, "Build defensive DCA preset from user configuration or defaults.",
    params: [
      params: [kind: :value, description: "DCA price and allocation configuration map"],
      entry_price: [kind: :value, description: "Entry price for price multiplier calculation"],
      side: [kind: :value, description: "Position side (:long or :short)"]
    ],
    returns: %{
      type: :list,
      description: "List of {price_multiplier, allocation_decimal} Decimal tuples"
    }
  )

  @doc """
  Build defensive DCA preset from user configuration or defaults.

  Defensive DCA goes against the current position direction:
  - For longs: buy at lower prices (averaging down)
  - For shorts: buy at higher prices (averaging up)

  ## Parameters
  - `params`: Parameters map containing DCA price and allocation configuration
  - `entry_price`: Entry price for calculating price multipliers (Decimal)
  - `side`: Position side (:long or :short)

  ## Returns
  List of {price_multiplier, allocation_decimal} tuples.

  ## Examples

      params = %{
        defensive_prices: [Decimal.new("2850"), Decimal.new("2700")],
        dca_allocations: [Decimal.new("40"), Decimal.new("30")]
      }

      build_defensive_preset(params, Decimal.new("3000"), :long)
      #=> [{Decimal.new("0.95"), Decimal.new("0.40")}, {Decimal.new("0.90"), Decimal.new("0.30")}]
  """
  @spec build_defensive_preset(map(), Decimal.t(), :long | :short) :: dca_preset()
  def build_defensive_preset(params, entry_price, side) do
    prices =
      resolve_prices(
        Map.get(params, :defensive_prices, []),
        Map.get(params, :dca_prices, [])
      )

    build_preset_from_prices(
      prices,
      Map.get(params, :dca_allocations, []),
      entry_price,
      side,
      :defensive
    )
  end

  api(
    :build_aggressive_preset,
    "Build aggressive DCA preset from user configuration or defaults.",
    params: [
      params: [kind: :value, description: "DCA price and allocation configuration map"],
      entry_price: [kind: :value, description: "Entry price for price multiplier calculation"],
      side: [kind: :value, description: "Position side (:long or :short)"]
    ],
    returns: %{
      type: :list,
      description: "List of {price_multiplier, allocation_decimal} Decimal tuples"
    }
  )

  @doc """
  Build aggressive DCA preset from user configuration or defaults.

  Aggressive DCA goes with the current position direction:
  - For longs: buy at higher prices (momentum trading)
  - For shorts: buy at lower prices (momentum trading)

  ## Parameters
  - `params`: Parameters map containing DCA price and allocation configuration
  - `entry_price`: Entry price for calculating price multipliers (Decimal)
  - `side`: Position side (:long or :short)

  ## Returns
  List of {price_multiplier, allocation_decimal} tuples.

  ## Examples

      params = %{
        aggressive_prices: [Decimal.new("3150"), Decimal.new("3300")],
        dca_allocations: [Decimal.new("40"), Decimal.new("30")]
      }

      build_aggressive_preset(params, Decimal.new("3000"), :long)
      #=> [{Decimal.new("1.05"), Decimal.new("0.40")}, {Decimal.new("1.10"), Decimal.new("0.30")}]
  """
  @spec build_aggressive_preset(map(), Decimal.t(), :long | :short) :: dca_preset()
  def build_aggressive_preset(params, entry_price, side) do
    prices =
      resolve_prices(
        Map.get(params, :aggressive_prices, []),
        Map.get(params, :dca_prices, [])
      )

    build_preset_from_prices(
      prices,
      Map.get(params, :dca_allocations, []),
      entry_price,
      side,
      :aggressive
    )
  end

  api(:enhance_dca_steps, "Enhance DCA steps with leverage-to-AUM and black swan safety metrics.",
    params: [
      steps: [kind: :value, description: "List of DCA steps from Calc.dca_ladder/8"],
      aum: [kind: :value, description: "Total assets under management"],
      black_swan_pct: [kind: :value, description: "Black swan threshold as decimal (0-1)"],
      entry_price: [kind: :value, description: "Entry price"],
      side: [kind: :value, description: "Position side (:long or :short)"]
    ],
    returns: %{
      type: :list,
      description:
        "Enhanced steps with leverage_to_aum, passes_black_swan, and black_swan_price fields"
    }
  )

  @doc """
  Enhance DCA steps with additional risk and portfolio metrics.

  Adds leverage-to-AUM ratios and black swan safety checks to each DCA step
  for comprehensive risk assessment at each ladder level.

  ## Parameters
  - `steps`: List of DCA steps from `Calc.dca_ladder/8`
  - `aum`: Total Assets Under Management (Decimal)
  - `black_swan_pct`: Black swan threshold as decimal (0-1)
  - `entry_price`: Entry price (Decimal)
  - `side`: Position side (:long or :short)

  ## Returns
  Enhanced list of DCA steps with additional fields:
  - `:leverage_to_aum` - Cumulative position size as percentage of total AUM
  - `:passes_black_swan` - Whether this step's liquidation passes black swan test
  - `:black_swan_price` - Black swan price level for reference

  ## Examples

      steps = [%{cumulative_notional: Decimal.new("1000"), new_liq: Decimal.new("2800"), ...}]

      enhance_dca_steps(steps, Decimal.new("50000"), Decimal.new("0.15"), Decimal.new("3000"), :long)
      #=> [%{..., leverage_to_aum: Decimal.new("0.02"), passes_black_swan: true, ...}]
  """
  @spec enhance_dca_steps([dca_step()], Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) ::
          [dca_step()]
  def enhance_dca_steps(steps, aum, black_swan_pct, entry_price, side) do
    Enum.map(steps, fn step ->
      leverage_to_aum = Calc.leverage_to_aum(step.cumulative_notional, aum)

      black_swan_price =
        if side == :long do
          Decimal.mult(entry_price, Decimal.sub(@default_one, black_swan_pct))
        else
          Decimal.mult(entry_price, Decimal.add(@default_one, black_swan_pct))
        end

      passes_black_swan =
        if side == :long do
          Decimal.compare(step.new_liq, black_swan_price) == :lt
        else
          Decimal.compare(step.new_liq, black_swan_price) == :gt
        end

      Map.merge(step, %{
        leverage_to_aum: Calc.quantize(leverage_to_aum),
        passes_black_swan: passes_black_swan,
        black_swan_price: Calc.quantize(black_swan_price)
      })
    end)
  end

  @spec build_dca_params(
          map(),
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          :long | :short,
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t()
        ) :: dca_params()
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp build_dca_params(
         params,
         position_with_tokens,
         dca_reserve,
         entry_price,
         ui_leverage,
         side,
         mmr_rate,
         mark_buffer,
         aum,
         black_swan_pct
       ) do
    %{
      params: params,
      position_with_tokens: position_with_tokens,
      dca_reserve: dca_reserve,
      entry_price: entry_price,
      ui_leverage: ui_leverage,
      side: side,
      mmr_rate: mmr_rate,
      mark_buffer: mark_buffer,
      aum: aum,
      black_swan_pct: black_swan_pct
    }
  end

  @spec resolve_prices(list(), list()) :: list()
  defp resolve_prices(primary, fallback) do
    case primary do
      [_ | _] -> primary
      _ -> fallback
    end
  end

  @spec build_preset_from_prices(
          list(),
          list(),
          Decimal.t(),
          :long | :short,
          :defensive | :aggressive
        ) ::
          dca_preset()
  defp build_preset_from_prices(prices, allocations, entry_price, side, strategy) do
    case prices do
      [_ | _] ->
        custom_preset_from_prices(prices, allocations, entry_price)

      _ ->
        default_preset_for_strategy(side, strategy)
    end
  end

  @spec custom_preset_from_prices(list(), list(), Decimal.t()) :: dca_preset()
  defp custom_preset_from_prices(prices, allocations, entry_price) do
    prices
    |> Enum.zip(allocations)
    |> Enum.map(fn {price, alloc} ->
      {Decimal.div(price, entry_price), Decimal.div(alloc, @default_hundred)}
    end)
  end

  @spec default_preset_for_strategy(:long | :short, :defensive | :aggressive) :: dca_preset()
  defp default_preset_for_strategy(side, strategy) do
    preset = Presets.load_dca_preset()

    case {side, strategy} do
      {:short, :defensive} -> Calc.convert_ladder_for_short(preset)
      {:long, :aggressive} -> Calc.convert_ladder_for_short(preset)
      _ -> preset
    end
  end
end
