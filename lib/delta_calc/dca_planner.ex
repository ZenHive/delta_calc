defmodule DeltaCalc.DCAPlanner do
  @moduledoc """
  DCA ladder planning and strategy management.

  Builds defensive and aggressive DCA presets, calculates reserve-funded ladder steps,
  and enhances those steps with portfolio metrics.
  """

  use Descripex, namespace: "/dca_planner"

  alias DeltaCalc.Decimal, as: DecimalInput
  alias DeltaCalc.{Leverage, Liquidation, Presets}

  @default_zero Decimal.new("0")
  @default_one Decimal.new("1")
  @default_hundred Decimal.new("100")

  @type dca_preset :: [{Decimal.t(), Decimal.t()}]
  @type dca_step :: map()
  @type mmr_schedule :: [{DecimalInput.input(), DecimalInput.input()}]
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

  api(:dca_ladder, "Calculate DCA ladder steps using reserve allocation.",
    params: [
      position: [
        kind: :value,
        description:
          "Initial position with :notional and :eff_lev as canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{notional: String.t(), eff_lev: String.t()}
      ],
      reserve: [
        kind: :value,
        description:
          "Reserve available for DCA as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      entry_price: [
        kind: :value,
        description:
          "Initial entry price as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      ui_lev: [
        kind: :value,
        description:
          "UI leverage for new positions as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      ladder_preset: [
        kind: :value,
        description:
          "List of side-specific {price_mult, reserve_pct} pairs whose exact values use canonical decimal strings; native Elixir callers may also pass Decimal or integer; multipliers are used as supplied"
      ],
      side: [
        kind: :value,
        description: "Position side (:long or :short) used for liquidation math",
        schema: :long | :short
      ],
      mmr_rate: [
        kind: :value,
        description:
          "Minimum margin requirement rate as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Optional `:mark_buffer` added to the applicable MMR and `:mmr_schedule` list " <>
            "of {minimum_notional, mmr_rate} tiers; " <>
            "exact values use canonical decimal strings and native Elixir callers may also pass Decimal or integer; " <>
            "the highest applicable threshold wins"
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with steps, final_avg_entry, final_notional, final_liq, final_eff_lev"
    }
  )

  @spec dca_ladder(
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          list(),
          :long | :short,
          Decimal.t(),
          keyword() | Decimal.t()
        ) :: map()
  def dca_ladder(
        position,
        reserve,
        entry_price,
        ui_lev,
        ladder_preset,
        side,
        mmr_rate,
        opts \\ []
      ) do
    reserve = DecimalInput.cast!(reserve)
    entry_price = DecimalInput.cast!(entry_price)
    ui_lev = DecimalInput.cast!(ui_lev)
    mmr_rate = DecimalInput.cast!(mmr_rate)
    {mark_buffer, mmr_schedule} = dca_options(opts)
    initial_notional = DecimalInput.cast!(position.notional)
    initial_eff_lev = DecimalInput.cast!(position.eff_lev)

    {steps, _final_state} =
      ladder_preset
      |> Enum.with_index(1)
      |> Enum.reduce({[], initialize_dca_state(position, reserve, entry_price)}, fn
        {{price_mult, reserve_pct}, step_num}, accumulator ->
          process_single_dca_step(
            accumulator,
            {price_mult, reserve_pct, step_num},
            {entry_price, ui_lev, reserve, mmr_rate, mark_buffer, mmr_schedule, side}
          )
      end)

    steps
    |> Enum.reverse()
    |> calculate_final_metrics({
      entry_price,
      initial_notional,
      initial_eff_lev,
      mmr_rate,
      mark_buffer,
      mmr_schedule,
      side
    })
  end

  api(:convert_ladder_for_short, "Convert a long DCA ladder preset to a short preset.",
    params: [
      long_preset: [
        kind: :value,
        description:
          "List of {price_mult, reserve_pct} pairs whose exact values use canonical decimal strings; native Elixir callers may also pass Decimal or integer."
      ]
    ],
    returns: %{
      type: :list,
      description: "List of {price_mult, reserve_pct} tuples for shorts"
    }
  )

  @spec convert_ladder_for_short(list()) :: list()
  def convert_ladder_for_short(long_preset) do
    Enum.map(long_preset, fn {price_mult, reserve_pct} ->
      price_mult = DecimalInput.cast!(price_mult)
      reserve_pct = DecimalInput.cast!(reserve_pct)
      {Decimal.sub(Decimal.new(2), price_mult), reserve_pct}
    end)
  end

  @spec initialize_dca_state(map(), Decimal.t(), Decimal.t()) :: map()
  defp initialize_dca_state(position, reserve, entry_price) do
    initial_notional = DecimalInput.cast!(position.notional)
    initial_eff_lev = DecimalInput.cast!(position.eff_lev)

    wallet_equity =
      if Decimal.compare(initial_eff_lev, @default_zero) == :gt,
        do: Decimal.div(initial_notional, initial_eff_lev),
        else: reserve

    %{
      cumulative_notional: initial_notional,
      cumulative_tokens: Decimal.div(initial_notional, entry_price),
      remaining_reserve: reserve,
      wallet_equity: wallet_equity,
      last_avg_entry: entry_price
    }
  end

  @spec process_single_dca_step(
          {list(), map()},
          {Decimal.t(), Decimal.t(), integer()},
          {Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), mmr_schedule(),
           :long | :short}
        ) :: {list(), map()}
  defp process_single_dca_step(
         {steps, state},
         {price_mult, reserve_pct, step_num},
         {entry_price, ui_lev, reserve, mmr_rate, mark_buffer, mmr_schedule, side}
       ) do
    dca_price = Decimal.mult(entry_price, DecimalInput.cast!(price_mult))

    actual_spend =
      reserve
      |> Decimal.mult(DecimalInput.cast!(reserve_pct))
      |> Decimal.min(state.remaining_reserve)

    if Decimal.compare(actual_spend, @default_zero) == :eq do
      {steps, state}
    else
      {step, cumulative_tokens, wallet_equity} =
        calculate_dca_step(
          state,
          {actual_spend, ui_lev, dca_price, mmr_rate, mark_buffer, mmr_schedule, side, step_num}
        )

      next_state = %{
        cumulative_notional: step.cumulative_notional,
        cumulative_tokens: cumulative_tokens,
        remaining_reserve: Decimal.sub(state.remaining_reserve, actual_spend),
        wallet_equity: wallet_equity,
        last_avg_entry: step.new_avg_entry
      }

      {[step | steps], next_state}
    end
  end

  @spec calculate_dca_step(
          map(),
          {Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), mmr_schedule(),
           :long | :short, integer()}
        ) :: {map(), Decimal.t(), Decimal.t()}
  defp calculate_dca_step(
         state,
         {actual_spend, ui_lev, dca_price, mmr_rate, mark_buffer, mmr_schedule, side, step_num}
       ) do
    new_notional = Decimal.mult(actual_spend, ui_lev)
    cumulative_notional = Decimal.add(state.cumulative_notional, new_notional)

    cumulative_tokens =
      state.cumulative_tokens
      |> Decimal.add(Decimal.div(new_notional, dca_price))

    new_avg_entry =
      if Decimal.compare(cumulative_tokens, @default_zero) == :gt,
        do: Decimal.div(cumulative_notional, cumulative_tokens),
        else: state.last_avg_entry

    new_eff_lev =
      cumulative_notional
      |> Leverage.effective_leverage(state.wallet_equity)
      |> decimal_result_or_zero()

    adjusted_mmr =
      calculate_adjusted_mmr(cumulative_notional, mmr_rate, mark_buffer, mmr_schedule)

    new_liq =
      new_avg_entry
      |> Liquidation.liquidation(new_eff_lev, adjusted_mmr, side)
      |> decimal_result_or_zero()

    step = %{
      step_num: step_num,
      dca_price: dca_price,
      spend: actual_spend,
      new_notional: new_notional,
      new_avg_entry: new_avg_entry,
      new_liq: new_liq,
      new_eff_lev: new_eff_lev,
      cumulative_notional: cumulative_notional
    }

    {step, cumulative_tokens, state.wallet_equity}
  end

  @spec calculate_tiered_mmr(Decimal.t(), Decimal.t(), mmr_schedule()) :: Decimal.t()
  defp calculate_tiered_mmr(notional, base_mmr, mmr_schedule) do
    notional_abs = Decimal.abs(notional)

    mmr_schedule
    |> Enum.reduce({nil, base_mmr}, fn {threshold, rate}, {selected_threshold, selected_rate} ->
      threshold = DecimalInput.cast!(threshold)
      rate = DecimalInput.cast!(rate)

      if tier_is_more_specific?(notional_abs, threshold, selected_threshold),
        do: {threshold, rate},
        else: {selected_threshold, selected_rate}
    end)
    |> elem(1)
  end

  @spec tier_is_more_specific?(Decimal.t(), Decimal.t(), Decimal.t() | nil) :: boolean()
  defp tier_is_more_specific?(notional, threshold, selected_threshold) do
    Decimal.compare(notional, threshold) in [:eq, :gt] and
      (is_nil(selected_threshold) or Decimal.compare(threshold, selected_threshold) == :gt)
  end

  @spec calculate_adjusted_mmr(Decimal.t(), Decimal.t(), Decimal.t(), mmr_schedule()) ::
          Decimal.t()
  defp calculate_adjusted_mmr(notional, base_mmr, mark_buffer, mmr_schedule) do
    notional
    |> calculate_tiered_mmr(base_mmr, mmr_schedule)
    |> Decimal.add(mark_buffer)
  end

  @spec dca_options(keyword() | Decimal.t()) :: {Decimal.t(), mmr_schedule()}
  defp dca_options(opts) when is_list(opts) do
    mark_buffer = opts |> Keyword.get(:mark_buffer, @default_zero) |> DecimalInput.cast!()
    {mark_buffer, Keyword.get(opts, :mmr_schedule, [])}
  end

  defp dca_options(mark_buffer), do: {DecimalInput.cast!(mark_buffer), []}

  @spec calculate_final_metrics(
          list(),
          {Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), mmr_schedule(),
           :long | :short}
        ) :: map()
  defp calculate_final_metrics(
         steps,
         {entry_price, initial_notional, initial_eff_lev, mmr_rate, mark_buffer, mmr_schedule,
          side}
       ) do
    if Enum.empty?(steps) do
      adjusted_mmr =
        calculate_adjusted_mmr(initial_notional, mmr_rate, mark_buffer, mmr_schedule)

      %{
        steps: [],
        final_avg_entry: entry_price,
        final_notional: initial_notional,
        final_liq:
          entry_price
          |> Liquidation.liquidation(initial_eff_lev, adjusted_mmr, side)
          |> decimal_result_or_zero(),
        final_eff_lev: initial_eff_lev
      }
    else
      last_step = List.last(steps)

      %{
        steps: steps,
        final_avg_entry: last_step.new_avg_entry,
        final_notional: last_step.cumulative_notional,
        final_liq: last_step.new_liq,
        final_eff_lev: last_step.new_eff_lev
      }
    end
  end

  @spec decimal_result_or_zero(Leverage.decimal_result() | Liquidation.decimal_result()) ::
          Decimal.t()
  defp decimal_result_or_zero(%Decimal{} = value), do: value
  defp decimal_result_or_zero({:error, _reason}), do: @default_zero

  api(
    :calculate_dca_ladder,
    "Calculate defensive and aggressive DCA ladder results when reserve is available.",
    params: [
      dca_params: [
        kind: :value,
        description:
          "Map with params, position_with_tokens, dca_reserve, entry_price, ui_leverage, side, mmr_rate, mark_buffer, aum, and black_swan_pct. Exact fields use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          params: %{
            optional(:dca_enabled) => boolean(),
            optional(:defensive_prices) => [String.t()],
            optional(:aggressive_prices) => [String.t()],
            optional(:dca_prices) => [String.t()],
            optional(:dca_allocations) => [String.t()]
          },
          position_with_tokens: %{notional: String.t(), eff_lev: String.t()},
          dca_reserve: String.t(),
          entry_price: String.t(),
          ui_leverage: String.t(),
          side: :long | :short,
          mmr_rate: String.t(),
          mark_buffer: String.t(),
          aum: String.t(),
          black_swan_pct: String.t()
        }
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
    - `mark_buffer`: Buffer added to the MMR used for liquidation calculations (Decimal)
    - `aum`: Total Assets Under Management (Decimal)
    - `black_swan_pct`: Black swan threshold as decimal (0-1)

  ## Returns
  Map with DCA ladder results, or `nil` if no DCA available:
  - `:defensive` - Defensive DCA strategy results (if available)
  - `:aggressive` - Aggressive DCA strategy results (if available)

  Each strategy contains:
  - `:steps` - List of enhanced DCA steps with safety metrics
  - Other fields from `dca_ladder/8` result

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

  @spec do_calculate_dca_ladder(dca_params()) :: dca_result() | nil
  defp do_calculate_dca_ladder(dca_params) do
    if Decimal.compare(dca_params.dca_reserve, @default_zero) == :gt and
         Map.get(dca_params.params, :dca_enabled, true) do
      defensive_preset =
        build_defensive_preset(dca_params.params, dca_params.entry_price, dca_params.side)

      aggressive_preset =
        build_aggressive_preset(dca_params.params, dca_params.entry_price, dca_params.side)

      defensive_result =
        dca_ladder(
          dca_params.position_with_tokens,
          dca_params.dca_reserve,
          dca_params.entry_price,
          dca_params.ui_leverage,
          defensive_preset,
          dca_params.side,
          dca_params.mmr_rate,
          mark_buffer: dca_params.mark_buffer
        )

      aggressive_result =
        dca_ladder(
          dca_params.position_with_tokens,
          dca_params.dca_reserve,
          dca_params.entry_price,
          dca_params.ui_leverage,
          aggressive_preset,
          dca_params.side,
          dca_params.mmr_rate,
          mark_buffer: dca_params.mark_buffer
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
      params: [
        kind: :value,
        description:
          "DCA prices and allocations use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          optional(:defensive_prices) => [String.t()],
          optional(:dca_prices) => [String.t()],
          optional(:dca_allocations) => [String.t()]
        }
      ],
      entry_price: [
        kind: :value,
        description:
          "Entry price for price multiplier calculation as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [
        kind: :value,
        description: "Position side (:long or :short)",
        schema: :long | :short
      ]
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
      params: [
        kind: :value,
        description:
          "DCA prices and allocations use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          optional(:aggressive_prices) => [String.t()],
          optional(:dca_prices) => [String.t()],
          optional(:dca_allocations) => [String.t()]
        }
      ],
      entry_price: [
        kind: :value,
        description:
          "Entry price for price multiplier calculation as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [
        kind: :value,
        description: "Position side (:long or :short)",
        schema: :long | :short
      ]
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
      steps: [
        kind: :value,
        description:
          "List of DCA steps from DCAPlanner.dca_ladder/8; exact step fields use canonical decimal strings for agent transport."
      ],
      aum: [
        kind: :value,
        description:
          "Total assets under management as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      black_swan_pct: [
        kind: :value,
        description:
          "Black swan threshold (0-1) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      entry_price: [
        kind: :value,
        description:
          "Entry price as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [
        kind: :value,
        description: "Position side (:long or :short)",
        schema: :long | :short
      ]
    ],
    returns: %{
      type: :list,
      description:
        "Enhanced steps with leverage_to_aum, passes_black_swan, and black_swan_price fields, or {:error, reason}"
    }
  )

  @doc """
  Enhance DCA steps with additional risk and portfolio metrics.

  Adds leverage-to-AUM ratios and black swan safety checks to each DCA step
  for comprehensive risk assessment at each ladder level.

  ## Parameters
  - `steps`: List of DCA steps from `dca_ladder/8`
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
          [dca_step()] | {:error, atom()}
  def enhance_dca_steps(steps, aum, black_swan_pct, entry_price, side) do
    Enum.reduce_while(steps, [], fn step, acc ->
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

      case Leverage.leverage_to_aum(step.cumulative_notional, aum) do
        %Decimal{} = leverage_to_aum ->
          step =
            Map.merge(step, %{
              leverage_to_aum: leverage_to_aum,
              passes_black_swan: passes_black_swan,
              black_swan_price: black_swan_price
            })

          {:cont, [step | acc]}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      enhanced_steps -> Enum.reverse(enhanced_steps)
    end
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
      {:short, :defensive} -> convert_ladder_for_short(preset)
      {:long, :aggressive} -> convert_ladder_for_short(preset)
      _ -> preset
    end
  end
end
