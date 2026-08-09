defmodule DeltaCalc.DeltaNeutral do
  @moduledoc """
  Base-numeraire exposure, settlement coverage, and delta-neutral rebalance math.

  Tagged option and inverse-perpetual inputs preserve provider unit semantics.
  Coverage and risk-target evaluation remain separate calculations and never
  produce an approval decision. This module does not price options or compute Greeks.
  """

  use Descripex, namespace: "/delta_neutral"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)
  @default_tolerance Decimal.new("0.0001")
  @default_instrument :perp

  @type position_kind :: :spot | :perp | :option
  @type position_side :: :long | :short

  @type exposure_error ::
          :ambiguous_settlement_input
          | :invalid_decimal
          | :invalid_delta_shape
          | :invalid_mark_shape
          | :invalid_quantity_shape
          | :mixed_delta_shape
          | :mixed_mark_shape
          | :mixed_quantity_shape
          | :non_positive_mark
          | :non_positive_spot
          | :unsupported_delta_semantic
          | :unsupported_exposure_kind
          | :unsupported_exposure_period
          | :unsupported_mark_unit
          | :unsupported_quantity_unit
          | :untagged_delta_semantic
          | :untagged_exposure_kind
          | :untagged_mark_unit
          | :untagged_quantity_unit

  @type calculation_error ::
          exposure_error()
          | :invalid_coverage_shape
          | :invalid_risk_target_shape
          | :negative_coverage_amount

  @type exposure_params :: map()

  @type coverage_params :: %{
          required(:eligible_base) => DecimalInput.input(),
          required(:existing_short_call_obligations) => DecimalInput.input(),
          required(:pending_sell_reservations) => DecimalInput.input(),
          required(:other_reservations) => DecimalInput.input(),
          required(:proposed_short_call_obligation) => DecimalInput.input()
        }

  @type coverage_result :: %{
          eligible_base: Decimal.t(),
          existing_reservations: %{
            short_call_obligations: Decimal.t(),
            pending_sell_reservations: Decimal.t(),
            other_reservations: Decimal.t(),
            total: Decimal.t()
          },
          proposed_short_call_obligation: Decimal.t(),
          total_obligation: Decimal.t(),
          remaining_capacity: Decimal.t(),
          uncovered_amount: Decimal.t(),
          fully_covered: boolean()
        }

  @type risk_target_params :: %{
          required(:base_numeraire_exposure) => DecimalInput.input(),
          required(:target_exposure) => DecimalInput.input(),
          required(:tolerance) => DecimalInput.input()
        }

  @type risk_target_result :: %{
          base_numeraire_exposure: Decimal.t(),
          target_exposure: Decimal.t(),
          tolerance: Decimal.t(),
          residual_exposure: Decimal.t(),
          within_target: boolean()
        }

  @type position :: %{
          required(:kind) => position_kind(),
          optional(:size) => DecimalInput.input(),
          optional(:notional) => DecimalInput.input(),
          optional(:side) => position_side(),
          optional(:delta) => DecimalInput.input()
        }

  @type rebalance_params :: %{
          required(:positions) => [position()],
          optional(:tolerance) => DecimalInput.input(),
          optional(:instrument) => :spot | :perp
        }

  @type rebalance_result :: %{
          net_delta: Decimal.t(),
          within_tolerance: boolean(),
          side: :long | :short | :none,
          size: Decimal.t(),
          instrument: :spot | :perp,
          signed_hedge: Decimal.t()
        }

  api(
    :base_numeraire_exposure,
    "Calculate signed base exposure from explicitly tagged option or inverse-perpetual facts.",
    params: [
      params: [
        kind: :value,
        description:
          "Tagged :option or :inverse_perpetual map. Exact values are canonical decimal strings; " <>
            "option quantity units are :base_currency or :contracts, inverse units are :usd_notional or :contracts, " <>
            "and option delta semantics are :black_scholes, :net_transaction_delta, or settlement-only :decayed_components.",
        schema: %{
          optional(:period) => :ordinary | :settlement,
          optional(:delta) => %{
            optional(:semantic) => :black_scholes | :net_transaction_delta | :decayed_components,
            optional(:value) => String.t(),
            optional(:decayed_delta) => String.t(),
            optional(:decayed_mark) => %{
              optional(:spot_price) => String.t(),
              unit: :base_currency | :quote_currency,
              value: String.t()
            }
          },
          optional(:mark) => %{
            optional(:spot_price) => String.t(),
            unit: :base_currency | :quote_currency,
            value: String.t()
          },
          quantity: %{
            optional(:base_contract_size) => String.t(),
            optional(:usd_contract_size) => String.t(),
            unit: :base_currency | :usd_notional | :contracts,
            value: String.t()
          },
          kind: :option | :inverse_perpetual
        }
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, signed Decimal base exposure} or {:error, named_reason}; no unit shape is inferred."
    }
  )

  @doc "Return signed base exposure from one explicitly tagged option or inverse-perpetual input."
  @spec base_numeraire_exposure(exposure_params()) ::
          {:ok, Decimal.t()} | {:error, exposure_error()}
  def base_numeraire_exposure(%{kind: :option, quantity: quantity} = params) do
    with {:ok, base_quantity} <- option_base_quantity(quantity),
         {:ok, unit_exposure} <- option_unit_exposure(params) do
      {:ok, Decimal.mult(base_quantity, unit_exposure)}
    end
  end

  def base_numeraire_exposure(%{kind: :inverse_perpetual, quantity: quantity, mark: mark}) do
    with {:ok, usd_notional} <- inverse_usd_notional(quantity),
         {:ok, mark_price} <- positive_decimal(mark, :non_positive_mark) do
      {:ok, Decimal.div(usd_notional, mark_price)}
    end
  end

  def base_numeraire_exposure(%{kind: :inverse_perpetual, quantity: _quantity}),
    do: {:error, :invalid_mark_shape}

  def base_numeraire_exposure(%{kind: kind})
      when kind in [:option, :inverse_perpetual],
      do: {:error, :invalid_quantity_shape}

  def base_numeraire_exposure(%{kind: _kind}), do: {:error, :unsupported_exposure_kind}
  def base_numeraire_exposure(params) when is_map(params), do: {:error, :untagged_exposure_kind}
  def base_numeraire_exposure(_params), do: {:error, :unsupported_exposure_kind}

  api(
    :settlement_coverage,
    "Calculate covered-call settlement capacity from caller-classified, disjoint base amounts.",
    params: [
      params: [
        kind: :value,
        description:
          "Map of eligible base inventory, existing short-call obligations, pending/open sell reservations, " <>
            "other reservations, and the proposed short-call obligation. All exact values are canonical decimal strings.",
        schema: %{
          eligible_base: String.t(),
          existing_short_call_obligations: String.t(),
          pending_sell_reservations: String.t(),
          other_reservations: String.t(),
          proposed_short_call_obligation: String.t()
        }
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, coverage map} with Decimal capacity and uncovered amounts, or {:error, named_reason}; never an approval."
    }
  )

  @doc "Return settlement capacity after existing disjoint reservations and a proposed obligation."
  @spec settlement_coverage(coverage_params()) ::
          {:ok, coverage_result()} | {:error, calculation_error()}
  def settlement_coverage(%{
        eligible_base: eligible_base,
        existing_short_call_obligations: short_calls,
        pending_sell_reservations: pending_sells,
        other_reservations: other_reservations,
        proposed_short_call_obligation: proposed
      }) do
    with {:ok, eligible_base} <- coverage_decimal(eligible_base),
         {:ok, short_calls} <- coverage_decimal(short_calls),
         {:ok, pending_sells} <- coverage_decimal(pending_sells),
         {:ok, other_reservations} <- coverage_decimal(other_reservations),
         {:ok, proposed} <- coverage_decimal(proposed) do
      existing_total =
        short_calls
        |> Decimal.add(pending_sells)
        |> Decimal.add(other_reservations)

      total_obligation = Decimal.add(existing_total, proposed)
      remaining_capacity = Decimal.sub(eligible_base, total_obligation)
      uncovered_amount = Decimal.sub(total_obligation, eligible_base)

      {:ok,
       %{
         eligible_base: eligible_base,
         existing_reservations: %{
           short_call_obligations: short_calls,
           pending_sell_reservations: pending_sells,
           other_reservations: other_reservations,
           total: existing_total
         },
         proposed_short_call_obligation: proposed,
         total_obligation: total_obligation,
         remaining_capacity: Decimal.max(remaining_capacity, @zero),
         uncovered_amount: Decimal.max(uncovered_amount, @zero),
         fully_covered: Decimal.compare(total_obligation, eligible_base) != :gt
       }}
    end
  end

  def settlement_coverage(_params), do: {:error, :invalid_coverage_shape}

  api(
    :risk_target,
    "Evaluate signed base-numeraire exposure against a caller-supplied target and tolerance.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with signed :base_numeraire_exposure, :target_exposure, and non-directional :tolerance as canonical decimal strings.",
        schema: %{
          base_numeraire_exposure: String.t(),
          target_exposure: String.t(),
          tolerance: String.t()
        }
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, risk-target map} with Decimal residual exposure and :within_target, or {:error, named_reason}; never an approval."
    }
  )

  @doc "Return the signed residual from a target and whether it is within absolute tolerance."
  @spec risk_target(risk_target_params()) ::
          {:ok, risk_target_result()} | {:error, calculation_error()}
  def risk_target(%{
        base_numeraire_exposure: exposure,
        target_exposure: target,
        tolerance: tolerance
      }) do
    with {:ok, exposure} <- DecimalInput.cast(exposure),
         {:ok, target} <- DecimalInput.cast(target),
         {:ok, tolerance} <- DecimalInput.cast(tolerance) do
      tolerance = Decimal.abs(tolerance)
      residual = Decimal.sub(exposure, target)

      {:ok,
       %{
         base_numeraire_exposure: exposure,
         target_exposure: target,
         tolerance: tolerance,
         residual_exposure: residual,
         within_target: residual |> Decimal.abs() |> Decimal.compare(tolerance) != :gt
       }}
    end
  end

  def risk_target(_params), do: {:error, :invalid_risk_target_shape}

  api(
    :net_delta,
    "Aggregate signed delta exposure across spot, perp, and option positions.",
    params: [
      positions: [
        kind: :value,
        description:
          "List of position maps with :kind (:spot, :perp, or :option). " <>
            "Options must include exchange-supplied :delta; spot/perp use :delta when " <>
            "present, otherwise signed :size or :notional with optional :side. " <>
            "Exact fields use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: [
          %{
            optional(:size) => String.t(),
            optional(:notional) => String.t(),
            optional(:side) => :long | :short,
            optional(:delta) => String.t(),
            kind: :spot | :perp | :option
          }
        ]
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Net signed delta exposure (positive = net long, negative = net short)."
    }
  )

  @doc """
  Sum signed delta exposure across `positions`.

  Option positions must include exchange-supplied `:delta` (not computed here).
  Spot and perp positions use `:delta` when present; otherwise derive signed
  exposure from `:size` or `:notional` and `:side` (default `:long`).
  """
  @spec net_delta([position()]) :: Decimal.t()
  def net_delta(positions) when is_list(positions) do
    positions
    |> Enum.reduce(@zero, fn position, acc ->
      acc |> Decimal.add(position_delta(position))
    end)
  end

  api(
    :rebalance_to_neutral,
    "Compute the hedge leg needed to flatten net delta within a tolerance.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :positions and optional :tolerance (default \"0.0001\") as a canonical decimal string, " <>
            "plus :instrument (:perp default, or :spot). Native Elixir callers may also pass Decimal or integer " <>
            "for exact fields and may pass a bare position list.",
        schema: %{
          optional(:tolerance) => String.t(),
          optional(:instrument) => :perp | :spot,
          positions: [
            %{
              optional(:size) => String.t(),
              optional(:notional) => String.t(),
              optional(:side) => :long | :short,
              optional(:delta) => String.t(),
              kind: :spot | :perp | :option
            }
          ]
        }
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :net_delta, :within_tolerance, :side (:long, :short, or :none), " <>
          ":size, :instrument, and :signed_hedge for Hedging distribution."
    }
  )

  @doc """
  Return the hedge adjustment to bring net delta to ~0 within `tolerance`.

  When already within tolerance, `:side` is `:none` and `:size` is zero.
  `:signed_hedge` is sized for `DeltaCalc.Hedging.suggest_hedge_distribution/1`.
  """
  @spec rebalance_to_neutral(rebalance_params() | [position()]) :: rebalance_result()
  def rebalance_to_neutral(positions) when is_list(positions) do
    rebalance_to_neutral(%{positions: positions})
  end

  def rebalance_to_neutral(%{positions: positions} = params) do
    tolerance =
      params |> Map.get(:tolerance, @default_tolerance) |> DecimalInput.cast!() |> Decimal.abs()

    instrument = Map.get(params, :instrument, @default_instrument)
    net = net_delta(positions)

    if within_tolerance?(net, tolerance) do
      %{
        net_delta: net,
        within_tolerance: true,
        side: :none,
        size: @zero,
        instrument: instrument,
        signed_hedge: signed_hedge(:none, @zero)
      }
    else
      {side, size} = hedge_leg(net)

      %{
        net_delta: net,
        within_tolerance: false,
        side: side,
        size: size,
        instrument: instrument,
        signed_hedge: signed_hedge(side, size)
      }
    end
  end

  @spec option_base_quantity(term()) :: {:ok, Decimal.t()} | {:error, exposure_error()}
  defp option_base_quantity(%{unit: :base_currency, value: value} = quantity) do
    if contract_size_key?(quantity) do
      {:error, :mixed_quantity_shape}
    else
      DecimalInput.cast(value)
    end
  end

  defp option_base_quantity(
         %{
           unit: :contracts,
           value: value,
           base_contract_size: contract_size
         } = quantity
       ) do
    if Map.has_key?(quantity, :usd_contract_size) do
      {:error, :mixed_quantity_shape}
    else
      multiply_decimals(value, contract_size)
    end
  end

  defp option_base_quantity(%{unit: unit}) when unit in [:base_currency, :contracts],
    do: {:error, :invalid_quantity_shape}

  defp option_base_quantity(%{unit: _unit}), do: {:error, :unsupported_quantity_unit}
  defp option_base_quantity(quantity) when is_map(quantity), do: {:error, :untagged_quantity_unit}
  defp option_base_quantity(_quantity), do: {:error, :invalid_quantity_shape}

  @spec inverse_usd_notional(term()) :: {:ok, Decimal.t()} | {:error, exposure_error()}
  defp inverse_usd_notional(%{unit: :usd_notional, value: value} = quantity) do
    if contract_size_key?(quantity) do
      {:error, :mixed_quantity_shape}
    else
      DecimalInput.cast(value)
    end
  end

  defp inverse_usd_notional(
         %{
           unit: :contracts,
           value: value,
           usd_contract_size: contract_size
         } = quantity
       ) do
    if Map.has_key?(quantity, :base_contract_size) do
      {:error, :mixed_quantity_shape}
    else
      multiply_decimals(value, contract_size)
    end
  end

  defp inverse_usd_notional(%{unit: unit}) when unit in [:usd_notional, :contracts],
    do: {:error, :invalid_quantity_shape}

  defp inverse_usd_notional(%{unit: _unit}), do: {:error, :unsupported_quantity_unit}
  defp inverse_usd_notional(quantity) when is_map(quantity), do: {:error, :untagged_quantity_unit}
  defp inverse_usd_notional(_quantity), do: {:error, :invalid_quantity_shape}

  @spec option_unit_exposure(exposure_params()) ::
          {:ok, Decimal.t()} | {:error, exposure_error()}
  defp option_unit_exposure(%{period: :settlement} = params),
    do: settlement_option_unit_exposure(params)

  defp option_unit_exposure(%{period: :ordinary} = params),
    do: ordinary_option_unit_exposure(params)

  defp option_unit_exposure(%{period: _period}), do: {:error, :unsupported_exposure_period}
  defp option_unit_exposure(params), do: ordinary_option_unit_exposure(params)

  @spec ordinary_option_unit_exposure(exposure_params()) ::
          {:ok, Decimal.t()} | {:error, exposure_error()}
  defp ordinary_option_unit_exposure(%{
         delta: %{semantic: :black_scholes, value: delta} = delta_shape,
         mark: mark
       }) do
    if decayed_component_key?(delta_shape) do
      {:error, :mixed_delta_shape}
    else
      subtract_base_mark(delta, mark)
    end
  end

  defp ordinary_option_unit_exposure(%{delta: %{semantic: :black_scholes}}),
    do: {:error, :invalid_mark_shape}

  defp ordinary_option_unit_exposure(
         %{
           delta: %{semantic: :net_transaction_delta, value: delta} = delta_shape
         } = params
       ) do
    if Map.has_key?(params, :mark) or decayed_component_key?(delta_shape) do
      {:error, :mixed_delta_shape}
    else
      DecimalInput.cast(delta)
    end
  end

  defp ordinary_option_unit_exposure(%{delta: %{semantic: :net_transaction_delta}}),
    do: {:error, :invalid_delta_shape}

  defp ordinary_option_unit_exposure(%{delta: %{semantic: :decayed_components}}),
    do: {:error, :unsupported_delta_semantic}

  defp ordinary_option_unit_exposure(%{delta: %{semantic: _semantic}}),
    do: {:error, :unsupported_delta_semantic}

  defp ordinary_option_unit_exposure(_params), do: {:error, :untagged_delta_semantic}

  @spec settlement_option_unit_exposure(exposure_params()) ::
          {:ok, Decimal.t()} | {:error, exposure_error()}
  defp settlement_option_unit_exposure(
         %{
           delta: %{semantic: :net_transaction_delta, value: delta} = delta_shape
         } = params
       ) do
    if Map.has_key?(params, :mark) or decayed_component_key?(delta_shape) do
      {:error, :mixed_delta_shape}
    else
      DecimalInput.cast(delta)
    end
  end

  defp settlement_option_unit_exposure(
         %{
           delta:
             %{
               semantic: :decayed_components,
               decayed_delta: delta,
               decayed_mark: mark
             } = delta_shape
         } = params
       ) do
    if Map.has_key?(params, :mark) or Map.has_key?(delta_shape, :value) do
      {:error, :mixed_delta_shape}
    else
      subtract_base_mark(delta, mark)
    end
  end

  defp settlement_option_unit_exposure(_params), do: {:error, :ambiguous_settlement_input}

  @spec subtract_base_mark(DecimalInput.input(), term()) ::
          {:ok, Decimal.t()} | {:error, exposure_error()}
  defp subtract_base_mark(delta, mark) do
    with {:ok, delta} <- DecimalInput.cast(delta),
         {:ok, base_mark} <- option_mark_to_base(mark) do
      {:ok, Decimal.sub(delta, base_mark)}
    end
  end

  @spec option_mark_to_base(term()) :: {:ok, Decimal.t()} | {:error, exposure_error()}
  defp option_mark_to_base(%{unit: :base_currency, value: value} = mark) do
    if Map.has_key?(mark, :spot_price) do
      {:error, :mixed_mark_shape}
    else
      DecimalInput.cast(value)
    end
  end

  defp option_mark_to_base(%{
         unit: :quote_currency,
         value: value,
         spot_price: spot_price
       }) do
    with {:ok, quote_mark} <- DecimalInput.cast(value),
         {:ok, spot_price} <- positive_decimal(spot_price, :non_positive_spot) do
      {:ok, Decimal.div(quote_mark, spot_price)}
    end
  end

  defp option_mark_to_base(%{unit: unit}) when unit in [:base_currency, :quote_currency],
    do: {:error, :invalid_mark_shape}

  defp option_mark_to_base(%{unit: _unit}), do: {:error, :unsupported_mark_unit}
  defp option_mark_to_base(mark) when is_map(mark), do: {:error, :untagged_mark_unit}
  defp option_mark_to_base(_mark), do: {:error, :invalid_mark_shape}

  @spec coverage_decimal(term()) :: {:ok, Decimal.t()} | {:error, calculation_error()}
  defp coverage_decimal(value) do
    with {:ok, value} <- DecimalInput.cast(value) do
      if Decimal.compare(value, @zero) == :lt do
        {:error, :negative_coverage_amount}
      else
        {:ok, value}
      end
    end
  end

  @spec positive_decimal(term(), exposure_error()) ::
          {:ok, Decimal.t()} | {:error, exposure_error()}
  defp positive_decimal(value, error) do
    with {:ok, value} <- DecimalInput.cast(value) do
      if Decimal.compare(value, @zero) == :gt, do: {:ok, value}, else: {:error, error}
    end
  end

  @spec multiply_decimals(term(), term()) ::
          {:ok, Decimal.t()} | {:error, exposure_error()}
  defp multiply_decimals(left, right) do
    with {:ok, left} <- DecimalInput.cast(left),
         {:ok, right} <- DecimalInput.cast(right) do
      {:ok, Decimal.mult(left, right)}
    end
  end

  @spec contract_size_key?(map()) :: boolean()
  defp contract_size_key?(quantity) do
    Map.has_key?(quantity, :base_contract_size) or Map.has_key?(quantity, :usd_contract_size)
  end

  @spec decayed_component_key?(map()) :: boolean()
  defp decayed_component_key?(delta) do
    Map.has_key?(delta, :decayed_delta) or Map.has_key?(delta, :decayed_mark)
  end

  @spec position_delta(position()) :: Decimal.t()
  defp position_delta(%{kind: :option} = position) do
    position |> Map.fetch!(:delta) |> DecimalInput.cast!()
  end

  defp position_delta(%{kind: kind} = position) when kind in [:spot, :perp] do
    case Map.get(position, :delta) do
      nil -> signed_size(position)
      delta -> DecimalInput.cast!(delta)
    end
  end

  @spec signed_size(position()) :: Decimal.t()
  defp signed_size(position) do
    position
    |> position_size()
    |> DecimalInput.cast!()
    |> Decimal.abs()
    |> apply_side(Map.get(position, :side, :long))
  end

  @spec position_size(position()) :: term()
  defp position_size(%{size: size}), do: size
  defp position_size(%{notional: notional}), do: notional

  defp position_size(position) do
    raise ArgumentError,
          "position requires :size or :notional, got: #{inspect(Map.drop(position, [:kind]))}"
  end

  @spec apply_side(Decimal.t(), position_side()) :: Decimal.t()
  defp apply_side(size, :short), do: Decimal.negate(size)
  defp apply_side(size, _), do: size

  @spec within_tolerance?(Decimal.t(), Decimal.t()) :: boolean()
  defp within_tolerance?(net, tolerance) do
    net |> Decimal.abs() |> Decimal.compare(tolerance) != :gt
  end

  @spec hedge_leg(Decimal.t()) :: {:long | :short, Decimal.t()}
  defp hedge_leg(net) do
    case Decimal.compare(net, @zero) do
      :gt -> {:short, net}
      _ -> {:long, Decimal.abs(net)}
    end
  end

  @spec signed_hedge(:long | :short | :none, Decimal.t()) :: Decimal.t()
  defp signed_hedge(:short, size), do: Decimal.negate(size)
  defp signed_hedge(:long, size), do: size
  defp signed_hedge(:none, _size), do: @zero
end
