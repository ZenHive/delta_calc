defmodule DeltaCalc.Allocation do
  @moduledoc """
  Subaccount allocation-envelope calculations.
  """

  use Descripex, namespace: "/allocation"

  alias DeltaCalc.Decimal, as: DecimalInput

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

  @spec allocate(Decimal.t(), map(), list(atom()), map(), Decimal.t()) :: map()
  def allocate(aum, mode_cfg, _assets, _weights, per_sub_cap_pct) do
    aum = DecimalInput.cast!(aum)
    mode_pct = DecimalInput.cast!(mode_cfg.pct)
    mode_cap = DecimalInput.cast!(mode_cfg.cap)
    per_sub_cap_pct = DecimalInput.cast!(per_sub_cap_pct)
    sub_eq = Decimal.min(Decimal.mult(aum, mode_pct), Decimal.mult(aum, mode_cap))
    init_margin = Decimal.mult(sub_eq, per_sub_cap_pct)

    %{
      sub_eq: sub_eq,
      init_margin: init_margin,
      reserve: Decimal.sub(sub_eq, init_margin),
      leftover: Decimal.sub(aum, sub_eq)
    }
  end
end
