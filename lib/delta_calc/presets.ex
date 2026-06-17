defmodule DeltaCalc.Presets do
  @moduledoc """
  Preset configurations for risk modes, black swan thresholds, and DCA ladder strategies.

  Provides hardcoded preset configurations for MVP usage. Future versions will
  load these from JSON configuration files for user customization.
  """

  use Descripex, namespace: "/presets"

  @type risk_mode :: %{
          pct: Decimal.t(),
          cap: Decimal.t()
        }

  @type asset_threshold :: %{
          long: integer(),
          short: integer()
        }

  @type dca_step :: {Decimal.t(), Decimal.t()}

  api(:load_modes, "Load risk mode configurations for portfolio allocation.",
    params: [],
    returns: %{
      type: :map,
      description:
        "Map with :conservative, :moderate, :aggressive keys, each a map of %{pct: Decimal, cap: Decimal}."
    }
  )

  @spec load_modes() :: %{
          conservative: risk_mode(),
          moderate: risk_mode(),
          aggressive: risk_mode()
        }
  def load_modes do
    %{
      conservative: %{
        pct: Decimal.new("0.01"),
        cap: Decimal.new("0.01")
      },
      moderate: %{
        pct: Decimal.new("0.03"),
        cap: Decimal.new("0.02")
      },
      aggressive: %{
        pct: Decimal.new("0.05"),
        cap: Decimal.new("0.03")
      }
    }
  end

  api(
    :load_thresholds,
    "Load black swan threshold percentages by asset for long and short positions.",
    params: [],
    returns: %{
      type: :map,
      description:
        "Map keyed by asset symbol (e.g. \"ETH\") to %{long: integer, short: integer} threshold percentages."
    }
  )

  @spec load_thresholds() :: %{String.t() => asset_threshold()}
  def load_thresholds do
    %{
      "ETH" => %{long: 25, short: 25},
      "BTC" => %{long: 20, short: 20},
      "SOL" => %{long: 30, short: 30}
    }
  end

  api(:load_dca_preset, "Load the default DCA ladder preset for reserve-based position scaling.",
    params: [],
    returns: %{
      type: :list,
      description:
        "3-step list of {price_pct, allocation_pct} Decimal tuples. " <>
          "Covers 90% of capital across decreasing price levels; 10% held in reserve."
    }
  )

  @spec load_dca_preset() :: list(dca_step())
  def load_dca_preset do
    [
      {Decimal.new("0.95"), Decimal.new("0.30")},
      {Decimal.new("0.90"), Decimal.new("0.30")},
      {Decimal.new("0.85"), Decimal.new("0.30")}
    ]
  end
end
