# DeltaCalc

Pure-`Decimal` calculation engine for leveraged crypto trading — **position sizing,
effective leverage, liquidation price, DCA ladders, safety scoring, spot hedging,
funding-rate math, account metrics, margin-bridge financing, and option-ladder strategies**.

Salvaged from the retired `TradingDashboard` app so a rebuild does not reinvent the math.
Every function is a pure value-in / value-out `Decimal` computation: no Ecto, no Phoenix,
no I/O. Drop it into any Elixir project (LiveView, CLI, Nx pipeline, agent tool) and call it.

## Installation (once published)

```elixir
def deps do
  [{:delta_calc, "~> 0.1"}]
end
```

## Quick start

```elixir
# In iex -S mix or any Elixir app with :delta_calc as a dependency
alias DeltaCalc.{
  Calc,
  Presets,
  DCAPlanner,
  PositionCalculator,
  Hedging,
  Funding,
  AccountMetrics,
  Concentration,
  MarginBridge,
  FundingProjection,
  OptionLadder,
  OptionsRisk
}
```

## `DeltaCalc.Calc`

Core engine: effective leverage, liquidation price, allocation envelopes, position sizing,
multi-leg aggregation, safety scoring, and DCA ladder math.

```elixir
# effective_leverage(notional, wallet_equity) -> Decimal
Calc.effective_leverage(Decimal.new(10_000), Decimal.new(5_000))
#=> #Decimal<2.00000000>

# leverage_to_aum(notional, total_aum) -> Decimal
Calc.leverage_to_aum(Decimal.new(10_000), Decimal.new(100_000))
#=> #Decimal<0.10000000>

# liquidation(entry, leff, mmr_total, side) -> Decimal
Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0.005"), :long)
#=> #Decimal<1507.50000000>
```

## `DeltaCalc.Presets`

Hardcoded risk modes, black-swan thresholds, and default DCA ladder steps.

```elixir
# load_modes/0 -> %{conservative: %{pct:, cap:}, moderate: ..., aggressive: ...}
Presets.load_modes().conservative
#=> %{pct: #Decimal<0.01>, cap: #Decimal<0.01>}

# load_thresholds/0 -> %{"ETH" => %{long:, short:}, ...}
Presets.load_thresholds()["ETH"]
#=> %{long: 25, short: 25}

# load_dca_preset/0 -> [{price_pct, allocation_pct}, ...]
Presets.load_dca_preset()
#=> [
#     {#Decimal<0.95>, #Decimal<0.30>},
#     {#Decimal<0.90>, #Decimal<0.30>},
#     {#Decimal<0.85>, #Decimal<0.30>}
#   ]
```

## `DeltaCalc.DCAPlanner`

Builds defensive/aggressive DCA presets and orchestrates full ladder calculations.

```elixir
params = %{
  defensive_prices: [Decimal.new("2850"), Decimal.new("2700")],
  dca_allocations: [Decimal.new("30"), Decimal.new("30")]
}

# build_defensive_preset(params, entry_price, side) -> [{price_mult, alloc}, ...]
DCAPlanner.build_defensive_preset(params, Decimal.new("3000"), :long)
#=> [
#     {#Decimal<0.95>, #Decimal<0.3>},
#     {#Decimal<0.9>, #Decimal<0.3>}
#   ]

dca_params = %{
  params: Map.put(params, :dca_enabled, true),
  position_with_tokens: %{
    notional: Decimal.new("100"),
    eff_lev: Decimal.new("2"),
    tokens: Decimal.new("0.03333333")
  },
  dca_reserve: Decimal.new("50"),
  entry_price: Decimal.new("3000"),
  ui_leverage: Decimal.new("2"),
  side: :long,
  mmr_rate: Decimal.new("0.005"),
  mark_buffer: Decimal.new("0.001"),
  aum: Decimal.new("10000"),
  black_swan_pct: Decimal.new("0.15")
}

# calculate_dca_ladder(dca_params) -> %{defensive: ..., aggressive: ...} | nil
DCAPlanner.calculate_dca_ladder(dca_params).defensive
#=> %{
#     final_avg_entry: #Decimal<2910.63829787>,
#     final_eff_lev: #Decimal<3.20000000>,
#     steps: [...],
#     ...
#   }
```

## `DeltaCalc.PositionCalculator`

Full position-sizing pipeline from a plain `params` map and `config` map.

```elixir
params = %{
  aum: Decimal.new("10000"),
  mode: :conservative,
  side: :long,
  entry_price: Decimal.new("3000"),
  subaccount_allocation: Decimal.new("100"),
  initial_position_pct: Decimal.new("0.5"),
  black_swan_pct: Decimal.new("0.15"),
  ui_leverage: Decimal.new("2"),
  mmr_rate: Decimal.new("0.005"),
  mark_buffer: Decimal.new("0.001"),
  fee_rate: Decimal.new("0.0004")
}

config = %{risk_modes: Presets.load_modes()}

result = PositionCalculator.calculate_position(params, config)
#=> %{
#     effective_leverage: #Decimal<1.00000000>,
#     leverage_to_aum: #Decimal<0.01000000>,
#     allocation: %{sub_eq: ..., init_position: ..., reserve: ..., ...},
#     position: %{notional: ..., eff_lev: ..., tokens: ...},
#     safety: %{
#       is_safe: true,
#       liquidation_price: #Decimal<18.00000000>,
#       black_swan_price: #Decimal<2550.00000000>,
#       ...
#     },
#     mmr_info: %{...}
#   }
```

## `DeltaCalc.Hedging`

Pure spot-hedging formulas: required CEX balance, coverage checks, and snapshot deltas.

```elixir
# calculate_required_cex_balance(total_spot, hedge_percent) -> Decimal
Hedging.calculate_required_cex_balance(Decimal.new("100000"), Decimal.new("60"))
#=> #Decimal<60000.0>

# check_hedge_coverage(cex_value, total_spot, target_hedge_percent)
Hedging.check_hedge_coverage(Decimal.new("60000"), Decimal.new("100000"), Decimal.new("60"))
#=> {:ok, #Decimal<60.00>}

prior = %{
  total_spot: Decimal.new("100000"),
  cex_spot: Decimal.new("60000"),
  cold_wallet: Decimal.new("40000"),
  hedge_coverage_pct: Decimal.new("60"),
  captured_at: ~U[2024-01-01 00:00:00Z]
}

current = %{
  total_spot: Decimal.new("110000"),
  cex_spot: Decimal.new("55000"),
  cold_wallet: Decimal.new("55000"),
  hedge_coverage_pct: Decimal.new("50"),
  captured_at: ~U[2024-01-01 01:00:00Z]
}

# calculate_change(prior, current) -> %{total_change:, cex_change:, ...}
Hedging.calculate_change(prior, current)
#=> %{
#     total_change: #Decimal<10000>,
#     cex_change: #Decimal<-5000>,
#     cold_change: #Decimal<15000>,
#     hedge_change: #Decimal<-10>,
#     duration_hours: 1.0
#   }
```

## `DeltaCalc.Funding`

Funding-rate APR annualisation, cross-venue comparison, arbitrage detection, and trend analysis.

```elixir
# funding_apr(rate, period_hours) -> {:ok, %{hourly, daily, annual}} | {:error, :invalid_rate}
Funding.funding_apr(Decimal.new("0.0001"), 8)
#=> {:ok, %{hourly: #Decimal<0.0013>, daily: #Decimal<0.03>, annual: #Decimal<10.95>}}

# compare_funding_rates(rates) -> comparison map per symbol
Funding.compare_funding_rates(%{binance: Decimal.new("0.0001"), bybit: Decimal.new("0.00015")})
#=> %{delta: #Decimal<0.00005>, arbitrage_opportunity: true, ranked: [...], ...}

# funding_trend(series) -> {:ok, trend} | {:error, :insufficient_data}
Funding.funding_trend([Decimal.new("0.0001"), Decimal.new("0.00012"), Decimal.new("0.00015")])
#=> {:ok, %{trend: :increasing, slope: #Decimal<...>, volatility: #Decimal<...>, ...}}
```

## `DeltaCalc.AccountMetrics`

Per-account liquidation, leverage, margin usage, and safety metrics.

```elixir
account = %{
  entry_price: Decimal.new("3000"),
  notional: Decimal.new("10000"),
  equity: Decimal.new("5000"),
  margin_used: Decimal.new("1000"),
  mmr_total: Decimal.new("0.005"),
  side: :long,
  swan_pct: Decimal.new("25")
}

# calculate(account, opts) -> %{effective_leverage, liquidation_price, ...}
AccountMetrics.calculate(account)
#=> %{
#     effective_leverage: #Decimal<2.00000000>,
#     liquidation_price: #Decimal<1507.50000000>,
#     liquidation_distance_pct: #Decimal<49.75000000>,
#     margin_usage_pct: #Decimal<20.00000000>,
#     safety: %{verdict: :tight, ...}
#   }

# margin_usage_pct(margin_used, equity) -> Decimal
AccountMetrics.margin_usage_pct(Decimal.new("1000"), Decimal.new("5000"))
#=> #Decimal<20.00000000>
```

## `DeltaCalc.Concentration`

Portfolio concentration risk via the Herfindahl-Hirschman Index (normalized 0–1 scale).

```elixir
weights = %{
  "BTC" => Decimal.new("0.45"),
  "ETH" => Decimal.new("0.30"),
  "SOL" => Decimal.new("0.15"),
  "Others" => Decimal.new("0.10")
}

# hhi(weights) -> Decimal
Concentration.hhi(weights)
#=> #Decimal<0.32500000>
```

## `DeltaCalc.MarginBridge`

Perp-funded option financing: margin ratios, runway, payback timelines, and kill-switch checks.

```elixir
# margin_ratio(initial_margin, option_premium, capital) -> Decimal
MarginBridge.margin_ratio(Decimal.new("6000"), Decimal.new("2700"), Decimal.new("60000"))
#=> #Decimal<0.145>

# margin_runway_days(available_margin, daily_burn) -> Decimal | nil
MarginBridge.margin_runway_days(Decimal.new("2025"), Decimal.new("45"))
#=> #Decimal<45>

# project_payback_timeline(remaining_debt, daily_funding, opts) -> payback map
MarginBridge.project_payback_timeline(Decimal.new("2430"), Decimal.new("90"))
#=> %{remaining_debt: #Decimal<2430>, daily_funding: #Decimal<90>, days_to_payoff: 27, ...}

# check_kill_switch(avg_funding_24h, margin_ratio, opts) -> kill-switch map
MarginBridge.check_kill_switch(Decimal.new("0.015"), Decimal.new("0.145"))
#=> %{kill_switch_triggered: false, avg_funding_24h: #Decimal<0.015>, ...}
```

## `DeltaCalc.FundingProjection`

Best-, expected-, and worst-case payback horizons from funding income and volatility.

```elixir
# project_payback_timeline(params) -> %{best_case, expected, worst_case}
FundingProjection.project_payback_timeline(%{
  remaining_debt: 2700,
  daily_funding: 90,
  funding_volatility: 0.2
})
#=> %{best_case: 25, expected: 30, worst_case: 38}
```

## `DeltaCalc.OptionLadder`

Rolling option ladder math: expiry selection, roll decisions, strike ladders, and funding sync.

```elixir
expiries = [
  %{expiry: "2026-03-07", days_to_expiry: 7, liquidity: Decimal.new("1.5"), bid_ask_spread: Decimal.new("0.05")},
  %{expiry: "2026-03-14", days_to_expiry: 14, liquidity: Decimal.new("1.2"), bid_ask_spread: Decimal.new("0.06")}
]

# optimal_expiries(expiries, opts) -> %{buckets, total_allocation}
OptionLadder.optimal_expiries(expiries)
#=> %{buckets: [%{bucket: :front, allocation: #Decimal<...>, ...}, ...], total_allocation: #Decimal<1>}

# check_roll_conditions(position, market) -> roll decision
position = %{days_to_expiry: 3, pnl_percent: "10", bid_ask_spread: "0.14"}
OptionLadder.check_roll_conditions(position, %{momentum: :flat})
#=> %{action: :roll, target: :next_weekly}

# iv_adjusted_size(base_size, opts) -> size adjustment map
OptionLadder.iv_adjusted_size(Decimal.new("100"), iv_percentile: 35)
#=> %{base_size: #Decimal<100>, adjusted_size: #Decimal<125.00>, action: :increase_size, ...}
```

## `DeltaCalc.OptionsRisk`

Long-option risk framing, gross exposure, negative-funding stress, and margin-bridge health.

```elixir
# max_loss(option_premiums) -> %{max_loss, risk_model, limited_downside}
OptionsRisk.max_loss(Decimal.new("2700"))
#=> %{max_loss: #Decimal<2700>, risk_model: :premium_only, limited_downside: true}

# calculate_total_exposure(legs) -> per-leg notionals + total_exposure
OptionsRisk.calculate_total_exposure(%{
  spot_notional: Decimal.new("60000"),
  perp_notional: Decimal.new("-60000"),
  options_notional: Decimal.new("2700"),
  margin_debt: Decimal.new("1800")
})
#=> %{spot_notional: #Decimal<60000>, total_exposure: #Decimal<124500>, ...}

# monitor_margin_bridge_health(params, opts) -> health map
OptionsRisk.monitor_margin_bridge_health(%{
  initial_margin: Decimal.new("6000"),
  option_premium: Decimal.new("2700"),
  capital: Decimal.new("60000"),
  available_margin: Decimal.new("2025"),
  daily_burn: Decimal.new("45")
})
#=> %{margin_ratio: #Decimal<0.145>, runway_days: #Decimal<45>, health_status: :healthy}
```

## Agent surface

Every public function carries an `api/3` declaration (via Descripex) for agent discovery.

```elixir
# JSON-serializable manifest of the full API
DeltaCalc.Manifest.build()

# MCP tool definitions for trading agents
DeltaCalc.Manifest.tools()

# Static export
mix descripex.manifest --pretty
```

## Provenance

Extracted from `TradingDashboard.Risk.*` (the `Calc`/`Presets`/`DCAPlanner`/`PositionCalculator`
modules) plus the pure hedging formulas from its `Portfolio` context. The original modules carry
~100 unit + StreamData property tests, ported alongside the code.

## Development

```bash
mix deps.get
mix test            # or: mix test.json
mix doctor          # 100% @doc + @spec on public API
mix docs              # ex_doc HTML output
mix descripex.manifest --pretty
mix precommit       # format + credo + doctor + tests
mix precommit.full  # + dialyzer
```