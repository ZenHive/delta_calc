defmodule DeltaCalc.Leverage do
  @moduledoc """
  Effective-leverage and position aggregation calculations.

  All functions use `Decimal` arithmetic and preserve the active `Decimal.Context` precision.
  """

  use Descripex, namespace: "/leverage"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)

  @type decimal_result :: Decimal.t() | {:error, atom()}

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

  @spec effective_leverage(Decimal.t(), Decimal.t()) :: decimal_result()
  def effective_leverage(notional, wallet_equity) do
    notional = DecimalInput.cast!(notional)
    wallet_equity = DecimalInput.cast!(wallet_equity)

    case Decimal.compare(wallet_equity, @zero) do
      :gt -> notional |> Decimal.abs() |> Decimal.div(wallet_equity)
      _ -> {:error, :non_positive_wallet_equity}
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

  @spec leverage_to_aum(Decimal.t(), Decimal.t()) :: decimal_result()
  def leverage_to_aum(notional, total_aum) do
    notional = DecimalInput.cast!(notional)
    total_aum = DecimalInput.cast!(total_aum)

    case Decimal.compare(total_aum, @zero) do
      :gt -> notional |> Decimal.abs() |> Decimal.div(total_aum)
      _ -> {:error, :non_positive_total_aum}
    end
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
      side: [kind: :value, description: "Position side (:long or :short)", schema: :long | :short]
    ],
    returns: %{type: :map, description: "Map with :notional and :eff_lev Decimal fields"}
  )

  @spec position(Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: map()
  def position(sub_eq, init_margin_pct, ui_lev, _entry, _side) do
    sub_eq = DecimalInput.cast!(sub_eq)
    init_margin_pct = DecimalInput.cast!(init_margin_pct)
    ui_lev = DecimalInput.cast!(ui_lev)
    notional = sub_eq |> Decimal.mult(init_margin_pct) |> Decimal.mult(ui_lev)

    %{
      notional: notional,
      eff_lev: notional |> effective_leverage(sub_eq) |> decimal_result_or_zero()
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

  @spec multi_leg_position(list(map()), Decimal.t(), Decimal.t(), :long | :short) :: map()
  def multi_leg_position(legs, current_price, initial_equity, side \\ :long) do
    current_price = DecimalInput.cast!(current_price)
    initial_equity = DecimalInput.cast!(initial_equity)
    {total_notional, total_pnl, total_tokens} = calculate_leg_totals(legs, current_price, side)
    avg_entry = calculate_average_entry(total_notional, total_tokens)
    current_equity = Decimal.add(initial_equity, total_pnl)

    %{
      total_notional: total_notional,
      avg_entry: avg_entry,
      unrealized_pnl: total_pnl,
      current_equity: current_equity,
      effective_leverage: calculate_effective_leverage(total_notional, current_equity)
    }
  end

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

  @spec calculate_average_entry(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_average_entry(total_notional, total_tokens) do
    if Decimal.compare(total_notional, @zero) == :gt and
         Decimal.compare(total_tokens, @zero) == :gt do
      Decimal.div(total_notional, total_tokens)
    else
      @zero
    end
  end

  @spec calculate_effective_leverage(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp calculate_effective_leverage(notional, equity) do
    if Decimal.compare(equity, @zero) == :gt,
      do: Decimal.div(notional, equity),
      else: @zero
  end

  @spec decimal_result_or_zero(decimal_result()) :: Decimal.t()
  defp decimal_result_or_zero(%Decimal{} = value), do: value
  defp decimal_result_or_zero({:error, _reason}), do: @zero
end
