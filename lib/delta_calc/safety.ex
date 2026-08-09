defmodule DeltaCalc.Safety do
  @moduledoc """
  Position safety scoring and before/after DCA safety comparisons.
  """

  use Descripex, namespace: "/safety"

  alias DeltaCalc.Decimal, as: DecimalInput
  alias DeltaCalc.{Leverage, Liquidation}

  @zero Decimal.new(0)
  @one Decimal.new(1)
  @hundred Decimal.new(100)
  @default_threshold_multiplier Decimal.new("1.5")
  @default_safe_multiplier Decimal.new("2.0")

  @type safety_result :: map() | {:error, :non_positive_entry}

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
      side: [kind: :value, description: "Position side (:long or :short)", schema: :long | :short],
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

  @spec safety(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short, map()) :: safety_result()
  def safety(liq, entry, swan_pct, side, cfg \\ %{}) do
    liq = DecimalInput.cast!(liq)
    entry = DecimalInput.cast!(entry)
    swan_pct = DecimalInput.cast!(swan_pct)

    if Decimal.compare(entry, @zero) in [:eq, :lt],
      do: {:error, :non_positive_entry},
      else: calculate_safety_metrics(liq, entry, swan_pct, side, cfg)
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
      side: [kind: :value, description: "Position side (:long or :short)", schema: :long | :short],
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

  @spec compare_dca_safety(
          map(),
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          :long | :short,
          Decimal.t(),
          map()
        ) :: map() | {:error, atom()}
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

    multi_position =
      Leverage.multi_leg_position([single_leg, dca_leg], current_price, initial_equity, side)

    with %Decimal{} = single_leverage <-
           Leverage.effective_leverage(single_notional, initial_equity),
         %Decimal{} = single_liquidation <-
           Liquidation.liquidation(single_entry, single_leverage, mmr, side),
         %Decimal{} = multi_liquidation <-
           Liquidation.liquidation(
             multi_position.avg_entry,
             multi_position.effective_leverage,
             mmr,
             side
           ),
         %{} = pre_dca_safety <-
           safety(single_liquidation, single_entry, swan_pct, side, safety_cfg),
         %{} = post_dca_safety <-
           safety(multi_liquidation, multi_position.avg_entry, swan_pct, side, safety_cfg) do
      %{
        pre_dca: pre_dca_safety,
        post_dca: post_dca_safety,
        leverage_change: Decimal.sub(multi_position.effective_leverage, single_leverage),
        liquidation_change: Decimal.sub(multi_liquidation, single_liquidation)
      }
    end
  end

  @spec calculate_safety_metrics(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short, map()) ::
          map()
  defp calculate_safety_metrics(liq, entry, swan_pct, side, cfg) do
    threshold_multiplier = Map.get(cfg, :threshold_multiplier, @default_threshold_multiplier)
    safe_multiplier = Map.get(cfg, :safe_multiplier, @default_safe_multiplier)
    {distance_pct, distance_usd} = calculate_liquidation_distance(liq, entry, side)
    {swan_distance_pct, swan_distance_usd} = calculate_swan_distance(entry, swan_pct, side)

    %{
      verdict:
        determine_safety_verdict(
          distance_pct,
          swan_pct,
          threshold_multiplier,
          safe_multiplier
        ),
      distance_to_liq_pct: distance_pct,
      distance_to_liq_usd: distance_usd,
      distance_to_swan_pct: swan_distance_pct,
      distance_to_swan_usd: swan_distance_usd,
      composite_score: calculate_composite_score(distance_pct, swan_pct)
    }
  end

  @spec calculate_liquidation_distance(Decimal.t(), Decimal.t(), :long | :short) ::
          {Decimal.t(), Decimal.t()}
  defp calculate_liquidation_distance(liq, entry, side) do
    difference =
      case side do
        :long -> Decimal.sub(entry, liq)
        :short -> Decimal.sub(liq, entry)
      end

    {Decimal.mult(Decimal.div(difference, entry), @hundred), difference}
  end

  @spec calculate_swan_distance(Decimal.t(), Decimal.t(), :long | :short) ::
          {Decimal.t(), Decimal.t()}
  defp calculate_swan_distance(entry, swan_pct, side) do
    swan_factor = Decimal.div(swan_pct, @hundred)

    swan_price =
      case side do
        :long -> Decimal.mult(entry, Decimal.sub(@one, swan_factor))
        :short -> Decimal.mult(entry, Decimal.add(@one, swan_factor))
      end

    {swan_pct, swan_price |> Decimal.sub(entry) |> Decimal.abs()}
  end

  @spec determine_safety_verdict(Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t()) ::
          :safe | :tight | :unsafe
  defp determine_safety_verdict(distance_pct, swan_pct, threshold_multiplier, safe_multiplier) do
    threshold = Decimal.mult(swan_pct, threshold_multiplier)
    safe_threshold = Decimal.mult(swan_pct, safe_multiplier)

    cond do
      Decimal.compare(distance_pct, safe_threshold) == :gt -> :safe
      Decimal.compare(distance_pct, threshold) == :gt -> :tight
      true -> :unsafe
    end
  end

  @spec calculate_composite_score(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_composite_score(distance_pct, swan_pct) do
    cond do
      Decimal.compare(distance_pct, @zero) == :lt ->
        @zero

      Decimal.compare(swan_pct, @zero) in [:eq, :lt] ->
        if Decimal.compare(distance_pct, @zero) == :gt, do: @hundred, else: @zero

      Decimal.compare(distance_pct, swan_pct) == :gt ->
        @hundred

      true ->
        Decimal.mult(Decimal.div(distance_pct, swan_pct), @hundred)
    end
  end
end
