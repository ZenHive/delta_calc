defmodule DeltaCalc.Calc do
  @moduledoc """
  Pure calculation functions for leverage, liquidation, allocation, and safety analysis.
  All functions use Decimal arithmetic exclusively and return the precision produced
  by the active `Decimal.Context`. Callers own tick-size, quantity-step, and reporting
  quantization; `quantize/1` exists only for the retired dashboard's eight-place
  compatibility boundary.

  ## Important: Simplified Modeling

  This module provides **analytical approximations** for planning purposes, not exact
  exchange-specific calculations. Real exchanges include additional factors:

  - Stepped margin tier structures (not constant MMR)
  - Fee buffers and insurance fund contributions
  - Mark price vs last price differences
  - Partial liquidation bands and incremental liquidations
  - Funding rate impacts over time
  - Cross-margin vs isolated margin specifics

  For exact liquidation prices, always refer to the specific exchange's API or
  risk engine. This module is designed for **position planning and risk assessment**
  rather than precise liquidation modeling.
  """

  use Descripex, namespace: "/calc"

  alias DeltaCalc.Decimal, as: DecimalInput

  @output_precision 8
  @zero Decimal.new(0)
  @one Decimal.new(1)
  @hundred Decimal.new(100)

  @type decimal_result :: Decimal.t() | {:error, atom()}
  @type safety_result :: map() | {:error, :non_positive_entry}
  @type mmr_schedule :: [{DecimalInput.input(), DecimalInput.input()}]

  api(:effective_leverage, "Calculate effective leverage from notional and wallet equity.",
    params: [
      notional: [
        kind: :value,
        description:
          "Position notional value as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      wallet_equity: [
        kind: :value,
        description:
          "Wallet/subaccount equity as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :decimal,
      description:
        "Effective leverage (notional / equity), or {:error, :non_positive_wallet_equity}"
    }
  )

  @doc """
  Calculates the effective leverage based on notional and wallet equity.
  Returns `{:error, :non_positive_wallet_equity}` for zero or negative equity.
  Uses absolute notional value for consistent leverage calculation.

  ## Examples

      iex> effective_leverage(Decimal.new(10000), Decimal.new(5000))
      #Decimal<2>

      iex> effective_leverage(Decimal.new(-10000), Decimal.new(5000))
      #Decimal<2>

      iex> effective_leverage(Decimal.new(10000), Decimal.new(0))
      {:error, :non_positive_wallet_equity}
  """
  @spec effective_leverage(Decimal.t(), Decimal.t()) :: decimal_result()
  def effective_leverage(notional, wallet_equity) do
    notional = DecimalInput.cast!(notional)
    wallet_equity = DecimalInput.cast!(wallet_equity)

    case Decimal.compare(wallet_equity, @zero) do
      :gt ->
        notional
        |> Decimal.abs()
        |> Decimal.div(wallet_equity)

      _ ->
        {:error, :non_positive_wallet_equity}
    end
  end

  api(:leverage_to_aum, "Calculate position notional as a fraction of total AUM.",
    params: [
      notional: [
        kind: :value,
        description:
          "Position notional value as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      total_aum: [
        kind: :value,
        description:
          "Total assets under management as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Exposure ratio (notional / AUM), or {:error, :non_positive_total_aum}"
    }
  )

  @doc """
  Calculates the position size as a percentage of total AUM (Assets Under Management).
  This shows what portion of the total portfolio is at risk in this position.

  Formula: notional_position_size / total_aum

  Note: The notional position size already includes leverage (position_size = margin * leverage),
  so this directly gives the exposure ratio without additional leverage multiplication.

  ## Examples

      iex> leverage_to_aum(Decimal.new(10000), Decimal.new(100000))
      #Decimal<0.1>  # 10% of AUM at risk

      iex> leverage_to_aum(Decimal.new(10000), Decimal.new(0))
      {:error, :non_positive_total_aum}
  """
  @spec leverage_to_aum(Decimal.t(), Decimal.t()) :: decimal_result()
  def leverage_to_aum(notional, total_aum) do
    notional = DecimalInput.cast!(notional)
    total_aum = DecimalInput.cast!(total_aum)

    case Decimal.compare(total_aum, @zero) do
      :gt ->
        notional
        |> Decimal.abs()
        |> Decimal.div(total_aum)

      _ ->
        {:error, :non_positive_total_aum}
    end
  end

  api(:liquidation, "Calculate liquidation price using simplified analytical model.",
    params: [
      entry: [
        kind: :value,
        description:
          "Entry price (> 0) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      leff: [
        kind: :value,
        description:
          "Effective leverage (>= 0) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      mmr_total: [
        kind: :value,
        description:
          "Total minimum margin requirement (0-1) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [
        kind: :value,
        description: "Position side (:long or :short)",
        schema: :long | :short
      ]
    ],
    returns: %{
      type: :decimal,
      description:
        "Estimated liquidation price, or {:error, :non_positive_entry | :negative_effective_leverage}"
    }
  )

  @doc """
  Calculates the liquidation price for a position using simplified analytical model.

  ## Parameters
    - entry: Entry price (must be > 0, returns `{:error, :non_positive_entry}` if ≤ 0)
    - leff: Effective leverage (must be ≥ 0, returns 0 if 0 and error if < 0)
    - mmr_total: Total minimum margin requirement (decimal 0-1, automatically clamped)
    - side: :long or :short

  ## Input Domains
    - entry: > 0 (positive price)
    - leff: ≥ 0 (non-negative leverage)
    - mmr_total: [0, 1] (percentage as decimal, automatically clamped to [0, 0.99999999])

  ## Formula
    - Long: entry * (1 - (1 - mmr_total) / leff)
    - Short: entry * (1 + (1 - mmr_total) / leff)

  ## Important Limitations
  This is a **simplified model** that assumes:
  - Constant MMR (no tier structures)
  - MMR includes trading fees (hence no separate fee parameter)
  - No funding or insurance buffers
  - Cross margin with equity = subaccount equity
  - Mark price = last price

  Real exchange liquidation prices will differ due to additional risk factors.
  Use this for planning and risk assessment, not exact liquidation prediction.

  ## Safety Guards
  - MMR is clamped to [0, 0.99999999] to prevent invalid values
  - Long liquidation prices are clamped to non-negative values
  - Returns 0 for zero leverage (no position)
  - Returns `{:error, :negative_effective_leverage}` for negative leverage
  - Returns `{:error, :non_positive_entry}` for non-positive entry

  ## Examples

      iex> liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0.005"), :long)
      #Decimal<1507.50000000>

      iex> liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0.005"), :short)
      #Decimal<4492.50000000>
  """
  @spec liquidation(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: decimal_result()
  def liquidation(entry, leff, mmr_total, side) do
    entry = DecimalInput.cast!(entry)
    leff = DecimalInput.cast!(leff)
    mmr_total = DecimalInput.cast!(mmr_total)

    # Clamp mmr_total to valid range [0, 0.99999999]
    mmr_total =
      mmr_total
      |> Decimal.max(@zero)
      |> Decimal.min(Decimal.new("0.99999999"))

    cond do
      Decimal.compare(entry, @zero) in [:lt, :eq] ->
        {:error, :non_positive_entry}

      Decimal.compare(leff, @zero) == :lt ->
        {:error, :negative_effective_leverage}

      Decimal.compare(leff, @zero) == :eq ->
        @zero

      true ->
        case side do
          :long ->
            # entry * (1 - (1 - mmr_total) / leff)
            one_minus_mmr = Decimal.sub(@one, mmr_total)
            factor = Decimal.div(one_minus_mmr, leff)

            liq =
              @one
              |> Decimal.sub(factor)
              |> Decimal.mult(entry)

            # Clamp long liquidation to non-negative values
            Decimal.max(liq, @zero)

          :short ->
            # entry * (1 + (1 - mmr_total) / leff)
            one_minus_mmr = Decimal.sub(@one, mmr_total)
            factor = Decimal.div(one_minus_mmr, leff)

            @one
            |> Decimal.add(factor)
            |> Decimal.mult(entry)
        end
    end
  end

  api(:allocate, "Compute subaccount equity envelope from mode configuration.",
    params: [
      aum: [
        kind: :value,
        description:
          "Assets under management as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      mode_cfg: [
        kind: :value,
        description:
          "Mode config with :pct and :cap as canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{pct: String.t(), cap: String.t()}
      ],
      assets: [
        kind: :value,
        description: "Asset symbols (interface compatibility)",
        schema: [String.t()]
      ],
      weights: [
        kind: :value,
        description:
          "Asset weight map (interface compatibility). Exact values use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: map()
      ],
      per_sub_cap_pct: [
        kind: :value,
        description:
          "Per-subaccount capital percentage (0-1) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with :sub_eq, :init_margin, :reserve, :leftover Decimal fields"
    }
  )

  @doc """
  Computes the subaccount equity envelope based on mode configuration.

  This function calculates the total subaccount allocation without distributing
  funds across individual assets. Asset-specific allocation is handled separately.

  ## Parameters
    - aum: Assets under management
    - mode_cfg: Mode configuration with %{pct: Decimal, cap: Decimal}
    - assets: List of asset symbols (for interface compatibility, not used)
    - weights: Map of asset => weight percentage (for interface compatibility, not used)
    - per_sub_cap_pct: Per-subaccount capital percentage (0-1)

  ## Returns
    Map with:
    - sub_eq: Subaccount equity envelope
    - init_margin: Initial margin available within the envelope
    - reserve: Reserve amount within the envelope
    - leftover: Unallocated amount remaining outside the envelope

  ## Example

      iex> allocate(Decimal.new(10000), %{pct: Decimal.new("0.01"), cap: Decimal.new("0.01")},
      ...>          [:ETH], %{ETH: Decimal.new(100)}, Decimal.new("0.5"))
      %{
        sub_eq: #Decimal<100.00000000>,
        init_margin: #Decimal<50.00000000>,
        reserve: #Decimal<50.00000000>,
        leftover: #Decimal<9900.00000000>
      }
  """
  @spec allocate(Decimal.t(), map(), list(atom()), map(), Decimal.t()) :: map()
  def allocate(aum, mode_cfg, _assets, _weights, per_sub_cap_pct) do
    aum = DecimalInput.cast!(aum)
    mode_pct = DecimalInput.cast!(mode_cfg.pct)
    mode_cap = DecimalInput.cast!(mode_cfg.cap)
    per_sub_cap_pct = DecimalInput.cast!(per_sub_cap_pct)

    # Calculate subaccount equity
    # Use minimum of (aum * mode_pct) and (aum * mode_cap)
    sub_eq_from_pct = Decimal.mult(aum, mode_pct)
    sub_eq_from_cap = Decimal.mult(aum, mode_cap)
    sub_eq = Decimal.min(sub_eq_from_pct, sub_eq_from_cap)

    # Calculate initial margin and reserve
    init_margin = Decimal.mult(sub_eq, per_sub_cap_pct)
    reserve = Decimal.sub(sub_eq, init_margin)

    # Calculate leftover (unallocated)
    leftover = Decimal.sub(aum, sub_eq)

    %{
      sub_eq: sub_eq,
      init_margin: init_margin,
      reserve: reserve,
      leftover: leftover
    }
  end

  api(:position, "Calculate position notional and effective leverage.",
    params: [
      sub_eq: [
        kind: :value,
        description:
          "Subaccount equity as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      init_margin_pct: [
        kind: :value,
        description:
          "Initial margin percentage (0-1) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      ui_lev: [
        kind: :value,
        description:
          "UI leverage (1-125) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      entry: [
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
      type: :map,
      description: "Map with :notional and :eff_lev Decimal fields"
    }
  )

  @doc """
  Calculates position size and effective leverage.

  ## Parameters
    - sub_eq: Subaccount equity
    - init_margin_pct: Initial margin percentage (0-1)
    - ui_lev: UI leverage (1-125)
    - entry: Entry price
    - side: :long or :short

  ## Returns
    Map with:
    - notional: Position notional value
    - eff_lev: Effective leverage

  For shorts, returns notional only (no token calculation).

  ## Example

      iex> position(Decimal.new(1000), Decimal.new("0.5"), Decimal.new(3),
      ...>          Decimal.new(3000), :long)
      %{
        notional: #Decimal<1500.00000000>,
        eff_lev: #Decimal<1.50000000>
      }
  """
  @spec position(Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: map()
  def position(sub_eq, init_margin_pct, ui_lev, _entry, _side) do
    sub_eq = DecimalInput.cast!(sub_eq)
    init_margin_pct = DecimalInput.cast!(init_margin_pct)
    ui_lev = DecimalInput.cast!(ui_lev)

    # Calculate initial margin
    init_margin = Decimal.mult(sub_eq, init_margin_pct)

    # Calculate notional: init_margin * ui_lev
    notional = Decimal.mult(init_margin, ui_lev)

    # Calculate effective leverage
    eff_lev =
      notional
      |> effective_leverage(sub_eq)
      |> decimal_result_or_zero()

    # For both long and short, return notional and effective leverage
    %{
      notional: notional,
      eff_lev: eff_lev
    }
  end

  api(:multi_leg_position, "Calculate side-aware multi-leg cross-margin position aggregates.",
    params: [
      legs: [
        kind: :value,
        description:
          "List of position legs whose :entry and :notional fields are canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: [%{entry: String.t(), notional: String.t()}]
      ],
      current_price: [
        kind: :value,
        description:
          "Current market price as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      initial_equity: [
        kind: :value,
        description:
          "Starting subaccount equity as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [
        kind: :value,
        default: :long,
        description: "Position side (:long or :short) used for unrealized PnL",
        schema: :long | :short
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with total_notional, avg_entry, unrealized_pnl, current_equity, effective_leverage"
    }
  )

  @doc """
  Calculates multi-leg position with cross-margin dynamics.

  In cross-margin, adding legs while price moves against you:
  1. Unrealized PnL reduces wallet equity
  2. New notional is added to existing notional
  3. Effective leverage typically increases (worse liquidation)

  ## Parameters
    - legs: List of %{entry: Decimal.t(), notional: Decimal.t()}
    - current_price: Current market price
    - initial_equity: Starting subaccount equity
    - side: :long or :short; defaults to :long

  ## Returns
    Map with:
    - total_notional: Combined notional across all legs
    - avg_entry: Volume-weighted average entry price
    - unrealized_pnl: Total unrealized profit/loss
    - current_equity: Remaining equity after unrealized PnL
    - effective_leverage: total_notional / current_equity

  ## Example

      iex> legs = [
      ...>   %{entry: Decimal.new(3000), notional: Decimal.new(125)},
      ...>   %{entry: Decimal.new(2800), notional: Decimal.new(125)}
      ...> ]
      iex> multi_leg_position(legs, Decimal.new(2800), Decimal.new(50), :long)
      %{
        total_notional: #Decimal<250.00000000>,
        avg_entry: #Decimal<2896.55172414>,
        unrealized_pnl: #Decimal<-8.33333333>,
        current_equity: #Decimal<41.66666667>,
        effective_leverage: #Decimal<6.00000000>
      }
  """
  @spec multi_leg_position(list(map()), Decimal.t(), Decimal.t(), :long | :short) :: map()
  def multi_leg_position(legs, current_price, initial_equity, side \\ :long) do
    current_price = DecimalInput.cast!(current_price)
    initial_equity = DecimalInput.cast!(initial_equity)

    # Calculate position aggregates
    {total_notional, total_pnl, total_tokens} =
      calculate_leg_totals(legs, current_price, side)

    # Calculate average entry price
    avg_entry = calculate_average_entry(total_notional, total_tokens)

    # Current equity after unrealized PnL
    current_equity = Decimal.add(initial_equity, total_pnl)

    # Effective leverage (guard against zero equity)
    eff_lev = calculate_effective_leverage(total_notional, current_equity)

    %{
      total_notional: total_notional,
      avg_entry: avg_entry,
      unrealized_pnl: total_pnl,
      current_equity: current_equity,
      effective_leverage: eff_lev
    }
  end

  # Calculate totals across all position legs
  @spec calculate_leg_totals(list(map()), Decimal.t(), :long | :short) ::
          {Decimal.t(), Decimal.t(), Decimal.t()}
  defp calculate_leg_totals(legs, current_price, side) do
    Enum.reduce(legs, {@zero, @zero, @zero}, fn leg, {notional_acc, pnl_acc, tokens_acc} ->
      entry = DecimalInput.cast!(leg.entry)
      notional = DecimalInput.cast!(leg.notional)
      tokens = Decimal.div(notional, entry)

      pnl =
        case side do
          :long -> Decimal.mult(tokens, Decimal.sub(current_price, entry))
          :short -> Decimal.mult(tokens, Decimal.sub(entry, current_price))
        end

      {
        Decimal.add(notional_acc, notional),
        Decimal.add(pnl_acc, pnl),
        Decimal.add(tokens_acc, tokens)
      }
    end)
  end

  # Calculate volume-weighted average entry price
  @spec calculate_average_entry(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_average_entry(total_notional, total_tokens) do
    if Decimal.compare(total_notional, @zero) == :gt and
         Decimal.compare(total_tokens, @zero) == :gt do
      Decimal.div(total_notional, total_tokens)
    else
      @zero
    end
  end

  # Calculate effective leverage with zero guard
  @spec calculate_effective_leverage(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_effective_leverage(notional, equity) do
    if Decimal.compare(equity, @zero) == :gt do
      Decimal.div(notional, equity)
    else
      @zero
    end
  end

  api(:safety, "Evaluate position safety and compute risk metrics.",
    params: [
      liq: [
        kind: :value,
        description:
          "Liquidation price as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      entry: [
        kind: :value,
        description:
          "Entry price (> 0) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      swan_pct: [
        kind: :value,
        description:
          "Black swan threshold percentage as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [
        kind: :value,
        description: "Position side (:long or :short)",
        schema: :long | :short
      ],
      cfg: [
        kind: :value,
        default: %{},
        description:
          "Safety config with :threshold_multiplier and :safe_multiplier as canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          optional(:threshold_multiplier) => String.t(),
          optional(:safe_multiplier) => String.t()
        }
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with verdict, distance metrics, and composite_score, or {:error, :non_positive_entry}"
    }
  )

  @doc """
  Evaluates position safety and calculates risk metrics.

  ## Parameters
    - liq: Liquidation price (any value)
    - entry: Entry price (must be > 0, returns `{:error, :non_positive_entry}` if ≤ 0)
    - swan_pct: Black swan percentage threshold (≥ 0, typically 0-100)
    - side: :long or :short
    - cfg: Safety configuration with thresholds

  ## Input Domains
    - entry: > 0 (positive price, guarded against division by zero)
    - swan_pct: ≥ 0 (non-negative percentage)
    - liq: any value (compared against entry)
    - cfg: optional map with threshold_multiplier and safe_multiplier

  ## Returns
    Map with:
    - verdict: :safe, :tight, or :unsafe
    - distance_to_liq_pct: Percentage distance to liquidation
    - distance_to_liq_usd: Dollar distance to liquidation
    - distance_to_swan_pct: Percentage distance to black swan
    - distance_to_swan_usd: Dollar distance to black swan
    - composite_score: Overall safety score (0-100)

  ## Safety Guards
    - Returns `{:error, :non_positive_entry}` if entry ≤ 0
    - Handles swan_pct = 0 without division errors
    - Caps composite score at 100 for distances beyond swan threshold

  ## Example

      iex> safety(Decimal.new(2850), Decimal.new(3000), Decimal.new(25), :long,
      ...>        %{threshold_multiplier: Decimal.new("1.5")})
      %{
        verdict: :safe,
        distance_to_liq_pct: #Decimal<5.00000000>,
        distance_to_liq_usd: #Decimal<150.00000000>,
        distance_to_swan_pct: #Decimal<20.00000000>,
        distance_to_swan_usd: #Decimal<600.00000000>,
        composite_score: #Decimal<75.00000000>
      }
  """
  @spec safety(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short, map()) :: safety_result()
  def safety(liq, entry, swan_pct, side, cfg \\ %{}) do
    liq = DecimalInput.cast!(liq)
    entry = DecimalInput.cast!(entry)
    swan_pct = DecimalInput.cast!(swan_pct)

    # Guard against zero or negative entry price
    if Decimal.compare(entry, @zero) in [:eq, :lt] do
      {:error, :non_positive_entry}
    else
      calculate_safety_metrics(liq, entry, swan_pct, side, cfg)
    end
  end

  # Calculate safety metrics for valid entry prices
  @spec calculate_safety_metrics(
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          :long | :short,
          map()
        ) :: map()
  defp calculate_safety_metrics(liq, entry, swan_pct, side, cfg) do
    # Default safety configuration
    threshold_multiplier = Map.get(cfg, :threshold_multiplier, Decimal.new("1.5"))
    safe_multiplier = Map.get(cfg, :safe_multiplier, Decimal.new("2.0"))

    # Calculate distances
    {distance_pct, distance_usd} = calculate_liquidation_distance(liq, entry, side)
    {swan_distance_pct, swan_distance_usd} = calculate_swan_distance(entry, swan_pct, side)

    # Determine verdict
    verdict =
      determine_safety_verdict(distance_pct, swan_pct, threshold_multiplier, safe_multiplier)

    # Calculate composite score
    score = calculate_composite_score(distance_pct, swan_pct)

    %{
      verdict: verdict,
      distance_to_liq_pct: distance_pct,
      distance_to_liq_usd: distance_usd,
      distance_to_swan_pct: swan_distance_pct,
      distance_to_swan_usd: swan_distance_usd,
      composite_score: score
    }
  end

  # Calculate distance to liquidation based on side
  @spec calculate_liquidation_distance(Decimal.t(), Decimal.t(), :long | :short) ::
          {Decimal.t(), Decimal.t()}
  defp calculate_liquidation_distance(liq, entry, side) do
    case side do
      :long ->
        # Long: liquidation is below entry
        diff = Decimal.sub(entry, liq)
        pct = Decimal.mult(Decimal.div(diff, entry), @hundred)
        {pct, diff}

      :short ->
        # Short: liquidation is above entry
        diff = Decimal.sub(liq, entry)
        pct = Decimal.mult(Decimal.div(diff, entry), @hundred)
        {pct, diff}
    end
  end

  # Calculate distance to black swan event
  @spec calculate_swan_distance(Decimal.t(), Decimal.t(), :long | :short) ::
          {Decimal.t(), Decimal.t()}
  defp calculate_swan_distance(entry, swan_pct, side) do
    swan_factor = Decimal.div(swan_pct, @hundred)

    swan_price =
      case side do
        :long ->
          # Long: swan is below entry
          Decimal.mult(entry, Decimal.sub(@one, swan_factor))

        :short ->
          # Short: swan is above entry
          Decimal.mult(entry, Decimal.add(@one, swan_factor))
      end

    swan_distance_usd = Decimal.abs(Decimal.sub(swan_price, entry))
    {swan_pct, swan_distance_usd}
  end

  # Determine safety verdict based on thresholds
  @spec determine_safety_verdict(
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t()
        ) :: :safe | :tight | :unsafe
  defp determine_safety_verdict(distance_pct, swan_pct, threshold_mult, safe_mult) do
    threshold = Decimal.mult(swan_pct, threshold_mult)
    safe_threshold = Decimal.mult(swan_pct, safe_mult)

    cond do
      Decimal.compare(distance_pct, safe_threshold) == :gt -> :safe
      Decimal.compare(distance_pct, threshold) == :gt -> :tight
      true -> :unsafe
    end
  end

  # Calculate composite safety score (0-100)
  @spec calculate_composite_score(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_composite_score(distance_pct, swan_pct) do
    cond do
      Decimal.compare(distance_pct, @zero) == :lt ->
        @zero

      Decimal.compare(swan_pct, @zero) in [:eq, :lt] ->
        # If no swan threshold, treat any positive distance as max safety
        if Decimal.compare(distance_pct, @zero) == :gt, do: @hundred, else: @zero

      Decimal.compare(distance_pct, swan_pct) == :gt ->
        # Beyond black swan threshold
        @hundred

      true ->
        # Linear scale from 0 to swan_pct
        Decimal.mult(Decimal.div(distance_pct, swan_pct), @hundred)
    end
  end

  api(:compare_dca_safety, "Compare safety metrics before and after adding a DCA leg.",
    params: [
      single_leg: [
        kind: :value,
        description:
          "Initial leg with :entry and :notional as canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{entry: String.t(), notional: String.t()}
      ],
      dca_leg: [
        kind: :value,
        description:
          "DCA leg with :entry and :notional as canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{entry: String.t(), notional: String.t()}
      ],
      current_price: [
        kind: :value,
        description:
          "Market price when adding DCA leg as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      initial_equity: [
        kind: :value,
        description:
          "Starting subaccount equity as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      mmr: [
        kind: :value,
        description:
          "Minimum margin requirement as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [
        kind: :value,
        description: "Position side (:long or :short)",
        schema: :long | :short
      ],
      swan_pct: [
        kind: :value,
        description:
          "Black swan threshold percentage as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      safety_cfg: [
        kind: :value,
        default: %{},
        description:
          "Optional safety configuration whose multiplier fields use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          optional(:threshold_multiplier) => String.t(),
          optional(:safe_multiplier) => String.t()
        }
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with pre_dca, post_dca, leverage_change, liquidation_change"
    }
  )

  @doc """
  Compares safety metrics before and after DCA for cross-margin positions.

  Useful for LiveView to show how adding legs affects liquidation distance.
  In cross-margin, DCA while underwater typically worsens safety metrics.

  ## Parameters
    - single_leg: %{entry: Decimal.t(), notional: Decimal.t()}
    - dca_leg: %{entry: Decimal.t(), notional: Decimal.t()}
    - current_price: Market price when adding DCA leg
    - initial_equity: Starting subaccount equity
    - mmr: Minimum margin requirement
    - side: :long or :short
    - swan_pct: Black swan threshold percentage
    - safety_cfg: Safety configuration (optional)

  ## Returns
    Map with:
    - pre_dca: Safety metrics before adding DCA leg
    - post_dca: Safety metrics after adding DCA leg
    - leverage_change: Difference in effective leverage
    - liquidation_change: Change in liquidation price (+ means worse for longs)

  ## Example

      iex> single = %{entry: Decimal.new(3000), notional: Decimal.new(125)}
      iex> dca = %{entry: Decimal.new(2800), notional: Decimal.new(125)}
      iex> compare_dca_safety(single, dca, Decimal.new(2800), Decimal.new(50),
      ...>                   Decimal.new("0.005"), :long, Decimal.new(25))
      %{
        pre_dca: %{verdict: :safe, distance_to_liq_pct: #Decimal<...>, ...},
        post_dca: %{verdict: :tight, distance_to_liq_pct: #Decimal<...>, ...},
        leverage_change: #Decimal<3.50000000>,  # 6.0x - 2.5x
        liquidation_change: #Decimal<610.00000000>  # $2416 - $1806
      }
  """
  @spec compare_dca_safety(
          map(),
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          :long | :short,
          Decimal.t(),
          map()
        ) ::
          map() | {:error, atom()}
  def compare_dca_safety(
        single_leg,
        dca_leg,
        current_price,
        initial_equity,
        mmr,
        side,
        swan_pct,
        safety_cfg \\ %{}
      ) do
    single_notional = DecimalInput.cast!(single_leg.notional)
    single_entry = DecimalInput.cast!(single_leg.entry)
    legs = [single_leg, dca_leg]
    multi_pos = multi_leg_position(legs, current_price, initial_equity, side)

    with %Decimal{} = single_lev <- effective_leverage(single_notional, initial_equity),
         %Decimal{} = single_liq <- liquidation(single_entry, single_lev, mmr, side),
         %Decimal{} = multi_liq <-
           liquidation(multi_pos.avg_entry, multi_pos.effective_leverage, mmr, side),
         %{} = pre_dca_safety <- safety(single_liq, single_entry, swan_pct, side, safety_cfg),
         %{} = post_dca_safety <-
           safety(multi_liq, multi_pos.avg_entry, swan_pct, side, safety_cfg) do
      leverage_change = Decimal.sub(multi_pos.effective_leverage, single_lev)
      liquidation_change = Decimal.sub(multi_liq, single_liq)

      %{
        pre_dca: pre_dca_safety,
        post_dca: post_dca_safety,
        leverage_change: leverage_change,
        liquidation_change: liquidation_change
      }
    end
  end

  # Helper functions

  @spec decimal_result_or_zero(decimal_result()) :: Decimal.t()
  defp decimal_result_or_zero(%Decimal{} = value), do: value
  defp decimal_result_or_zero({:error, _reason}), do: @zero

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

  @doc """
  Converts a long DCA ladder preset to a short preset.

  For shorts, we want to add to positions at higher prices (when price moves against us).
  This function converts long ladder multipliers (< 1.0) to short multipliers (> 1.0).

  ## Parameters
    - long_preset: List of {price_mult, reserve_pct} tuples for longs

  ## Returns
    List of {price_mult, reserve_pct} tuples for shorts

  ## Example

      iex> long_preset = [{Decimal.new("0.95"), Decimal.new("0.3")},
      ...>                {Decimal.new("0.90"), Decimal.new("0.3")}]
      iex> convert_ladder_for_short(long_preset)
      [{#Decimal<1.05>, #Decimal<0.3>}, {#Decimal<1.10>, #Decimal<0.3>}]
  """
  @spec convert_ladder_for_short(list()) :: list()
  def convert_ladder_for_short(long_preset) do
    Enum.map(long_preset, fn {price_mult, reserve_pct} ->
      price_mult = DecimalInput.cast!(price_mult)
      reserve_pct = DecimalInput.cast!(reserve_pct)

      # Convert: if long is 0.95 (5% down), short should be 1.05 (5% up)
      # Formula: short_mult = 2 - long_mult
      short_mult = Decimal.sub(Decimal.new(2), price_mult)

      {short_mult, reserve_pct}
    end)
  end

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

  @doc """
  Calculates DCA ladder steps for a position with reserve allocation.

  This function models adding to a position at different price levels using reserve funds.
  Each step recalculates the average entry price and liquidation level based on the
  cumulative position. The function ensures reserve is never overspent.

  ## Parameters
    - position: Initial position map with :notional and :eff_lev
    - reserve: Reserve amount available for DCA
    - entry_price: Initial entry price
    - ui_lev: UI leverage for new positions
    - ladder_preset: List of side-specific {price_mult, reserve_pct} tuples. Multipliers
      are used as supplied rather than transformed from `side`.
    - side: :long or :short; drives liquidation math
    - mmr_rate: Minimum margin requirement rate
    - opts: Optional keyword list. `:mark_buffer` is added to the MMR used by
      liquidation calculations. `:mmr_schedule` accepts `{minimum_notional, mmr_rate}`
      tiers; the highest threshold not exceeding cumulative notional applies.
      Passing a Decimal directly remains supported as shorthand for `:mark_buffer`.

  ## Returns
    Map with:
    - steps: List of DCA steps with details
    - final_avg_entry: Final average entry price
    - final_notional: Total notional after all DCA steps
    - final_liq: Final liquidation price
    - final_eff_lev: Final effective leverage

  ## Example

      iex> position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      iex> ladder_preset = [{Decimal.new("0.95"), Decimal.new("0.3")},
      ...>                 {Decimal.new("0.90"), Decimal.new("0.3")}]
      iex> dca_ladder(position, Decimal.new(500), Decimal.new(3000), Decimal.new(3),
      ...>            ladder_preset, :long, Decimal.new("0.005"))
      %{
        steps: [...],
        final_avg_entry: #Decimal<...>,
        final_notional: #Decimal<...>,
        final_liq: #Decimal<...>,
        final_eff_lev: #Decimal<...>
      }
  """
  @spec dca_ladder(
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          list(),
          :long | :short,
          Decimal.t(),
          keyword() | Decimal.t()
        ) ::
          map()
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

    # Initialize state
    initial_state = initialize_dca_state(position, reserve, entry_price)

    # Process each ladder step
    {steps, _final_state} =
      ladder_preset
      |> Enum.with_index(1)
      |> Enum.reduce({[], initial_state}, fn {{price_mult, reserve_pct}, step_num},
                                             {steps_acc, state} ->
        process_single_dca_step(
          {steps_acc, state},
          {price_mult, reserve_pct, step_num},
          {entry_price, ui_lev, reserve, mmr_rate, mark_buffer, mmr_schedule, side}
        )
      end)

    # Reverse steps to maintain order
    steps = Enum.reverse(steps)

    # Calculate final metrics
    calculate_final_metrics(steps, {
      entry_price,
      initial_notional,
      initial_eff_lev,
      mmr_rate,
      mark_buffer,
      mmr_schedule,
      side
    })
  end

  @spec initialize_dca_state(map(), Decimal.t(), Decimal.t()) :: map()
  defp initialize_dca_state(position, reserve, entry_price) do
    initial_notional = DecimalInput.cast!(position.notional)
    initial_eff_lev = DecimalInput.cast!(position.eff_lev)

    wallet_equity =
      if Decimal.compare(initial_eff_lev, @zero) == :gt do
        Decimal.div(initial_notional, initial_eff_lev)
      else
        # If no leverage, equity equals reserve
        reserve
      end

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
         {steps_acc, state},
         {price_mult, reserve_pct, step_num},
         {entry_price, ui_lev, reserve, mmr_rate, mark_buffer, mmr_schedule, side}
       ) do
    price_mult = DecimalInput.cast!(price_mult)
    reserve_pct = DecimalInput.cast!(reserve_pct)

    dca_price = calculate_dca_price(entry_price, price_mult)

    # Calculate spend amount (percentage of original reserve, clamped to remaining)
    # Using original reserve for predictable behavior - each step gets its configured % of initial reserve
    target_spend = Decimal.mult(reserve, reserve_pct)
    actual_spend = Decimal.min(target_spend, state.remaining_reserve)

    # Skip if no reserve left
    if Decimal.compare(actual_spend, @zero) == :eq do
      {steps_acc, state}
    else
      step_result =
        calculate_dca_step(
          state,
          {actual_spend, ui_lev, dca_price, mmr_rate, mark_buffer, mmr_schedule, side, step_num}
        )

      # Update state for next iteration
      new_state = update_dca_state(state, step_result, actual_spend)

      {[step_result | steps_acc], new_state}
    end
  end

  @spec calculate_dca_price(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_dca_price(entry_price, price_mult) do
    Decimal.mult(entry_price, price_mult)
  end

  @spec calculate_dca_step(
          map(),
          {Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), mmr_schedule(),
           :long | :short, integer()}
        ) :: map()
  defp calculate_dca_step(
         state,
         {actual_spend, ui_lev, dca_price, mmr_rate, mark_buffer, mmr_schedule, side, step_num}
       ) do
    # Calculate new position metrics
    new_notional = Decimal.mult(actual_spend, ui_lev)
    new_tokens = Decimal.div(new_notional, dca_price)

    # Update cumulative position
    cumulative_notional = Decimal.add(state.cumulative_notional, new_notional)
    cumulative_tokens = Decimal.add(state.cumulative_tokens, new_tokens)

    # Calculate new average entry price
    new_avg_entry =
      if Decimal.compare(cumulative_tokens, @zero) == :gt do
        Decimal.div(cumulative_notional, cumulative_tokens)
      else
        state.last_avg_entry
      end

    # Wallet equity remains the same (cross-margin uses existing equity)
    # The spend comes from reserve, not added to equity
    new_wallet_equity = state.wallet_equity

    # Calculate new effective leverage
    new_eff_lev =
      cumulative_notional
      |> effective_leverage(new_wallet_equity)
      |> decimal_result_or_zero()

    adjusted_mmr_rate =
      calculate_adjusted_mmr(cumulative_notional, mmr_rate, mark_buffer, mmr_schedule)

    new_liq =
      new_avg_entry
      |> liquidation(new_eff_lev, adjusted_mmr_rate, side)
      |> decimal_result_or_zero()

    %{
      step_num: step_num,
      dca_price: dca_price,
      spend: actual_spend,
      new_notional: new_notional,
      new_avg_entry: new_avg_entry,
      new_liq: new_liq,
      new_eff_lev: new_eff_lev,
      cumulative_notional: cumulative_notional,
      # Internal fields for state tracking
      _cumulative_tokens: cumulative_tokens,
      _new_wallet_equity: new_wallet_equity
    }
  end

  @spec update_dca_state(map(), map(), Decimal.t()) :: map()
  defp update_dca_state(state, step_result, actual_spend) do
    %{
      cumulative_notional: step_result.cumulative_notional,
      cumulative_tokens: step_result._cumulative_tokens,
      remaining_reserve: Decimal.sub(state.remaining_reserve, actual_spend),
      wallet_equity: step_result._new_wallet_equity,
      last_avg_entry: step_result.new_avg_entry
    }
  end

  @spec calculate_tiered_mmr(Decimal.t(), Decimal.t(), mmr_schedule()) :: Decimal.t()
  defp calculate_tiered_mmr(notional, base_mmr, mmr_schedule) do
    notional_abs = Decimal.abs(notional)

    mmr_schedule
    |> Enum.reduce({nil, base_mmr}, fn {threshold, rate}, {selected_threshold, selected_rate} ->
      threshold = DecimalInput.cast!(threshold)
      rate = DecimalInput.cast!(rate)

      if tier_is_more_specific?(notional_abs, threshold, selected_threshold) do
        {threshold, rate}
      else
        {selected_threshold, selected_rate}
      end
    end)
    |> elem(1)
  end

  @spec tier_is_more_specific?(Decimal.t(), Decimal.t(), Decimal.t() | nil) :: boolean()
  defp tier_is_more_specific?(notional, threshold, selected_threshold) do
    applies? = Decimal.compare(notional, threshold) in [:eq, :gt]

    applies? and
      (is_nil(selected_threshold) or Decimal.compare(threshold, selected_threshold) == :gt)
  end

  @spec calculate_adjusted_mmr(
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          mmr_schedule()
        ) :: Decimal.t()
  defp calculate_adjusted_mmr(notional, base_mmr, mark_buffer, mmr_schedule) do
    notional
    |> calculate_tiered_mmr(base_mmr, mmr_schedule)
    |> Decimal.add(mark_buffer)
  end

  @spec dca_options(keyword() | Decimal.t()) :: {Decimal.t(), mmr_schedule()}
  defp dca_options(opts) when is_list(opts) do
    mark_buffer = opts |> Keyword.get(:mark_buffer, @zero) |> DecimalInput.cast!()
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
      %{
        steps: [],
        final_avg_entry: entry_price,
        final_notional: initial_notional,
        final_liq:
          entry_price
          |> liquidation(
            initial_eff_lev,
            calculate_adjusted_mmr(initial_notional, mmr_rate, mark_buffer, mmr_schedule),
            side
          )
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

  api(:quantize, "Round a Decimal to the retired dashboard's eight-place compatibility format.",
    params: [
      value: [
        kind: :value,
        description:
          "Value to quantize as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{type: :decimal, description: "Value rounded to the legacy 8-place format"}
  )

  @doc """
  Quantizes a Decimal value to the retired dashboard's eight-place output format.

  Generic calculations do not call this function. New callers should apply their
  instrument step or reporting precision at their own output boundary.
  """
  @spec quantize(Decimal.t()) :: Decimal.t()
  def quantize(value) do
    Decimal.round(value, @output_precision)
  end
end
