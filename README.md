# DeltaCalc

Pure-`Decimal` calculation engine for leveraged crypto trading — **position sizing,
effective leverage, liquidation price, DCA ladders, safety scoring, spot hedging,
funding-rate math, account metrics, margin-bridge financing, option-ladder strategies,
position PnL, delta-neutral rebalancing, portfolio-margin netting, stress scenarios,
fee math, and spot/perp carry analysis**.

Salvaged from the retired `TradingDashboard` app so a rebuild does not reinvent the math.
Every function is a pure value-in / value-out `Decimal` computation: no Ecto, no Phoenix,
no I/O. Drop it into any Elixir project (LiveView, CLI, Nx pipeline, agent tool) and call it.

## Installation (once published)

```elixir
def deps do
  [{:delta_calc, "~> 0.3"}]
end
```

## Quick start

```elixir
# In iex -S mix or any Elixir app with :delta_calc as a dependency
alias DeltaCalc.{
  Calc,
  Leverage,
  Liquidation,
  Allocation,
  Safety,
  Presets,
  DCAPlanner,
  Quantization,
  PositionCalculator,
  Hedging,
  Funding,
  AccountMetrics,
  Concentration,
  MarginBridge,
  FundingProjection,
  OptionLadder,
  OptionsRisk,
  Pnl,
  DeltaNeutral,
  PortfolioMargin,
  StressScenario,
  Fees,
  Carry
}
```

## `DeltaCalc.Calc`

Compatibility façade preserving the original entry points. The focused implementation modules
are `Leverage`, `Liquidation`, `Allocation`, `Safety`, `DCAPlanner`, and `Quantization`.

```elixir
# effective_leverage(notional, wallet_equity) -> Decimal
Calc.effective_leverage(Decimal.new(10_000), Decimal.new(5_000))
#=> #Decimal<2>

# leverage_to_aum(notional, total_aum) -> Decimal
Calc.leverage_to_aum(Decimal.new(10_000), Decimal.new(100_000))
#=> #Decimal<0.1>

# liquidation(entry, leff, mmr_total, side) -> Decimal
Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0.005"), :long)
#=> #Decimal<1507.5000>
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

Full position-sizing pipeline from a plain `params` map.

```elixir
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

result = PositionCalculator.calculate_position(params)
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
#=> {:ok, %{hourly: #Decimal<0.0012500>, daily: #Decimal<0.0300>, annual: #Decimal<10.9500>}}

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
#=> #Decimal<0.3250>
```

## `DeltaCalc.MarginBridge`

Perp-funded option financing: margin ratios, runway, payback timelines, and kill-switch checks.
Single-scenario `payback_timeline/3` differs from `FundingProjection.project_payback_timeline/1` (volatility scenarios).

```elixir
# margin_ratio(initial_margin, option_premium, capital) -> Decimal
MarginBridge.margin_ratio(Decimal.new("6000"), Decimal.new("2700"), Decimal.new("60000"))
#=> #Decimal<0.145>

# margin_runway_days(available_margin, daily_burn) -> Decimal | nil
MarginBridge.margin_runway_days(Decimal.new("2025"), Decimal.new("45"))
#=> #Decimal<45>

# payback_timeline(remaining_debt, daily_funding, opts) -> payback map
MarginBridge.payback_timeline(Decimal.new("2430"), Decimal.new("90"))
#=> %{remaining_debt: #Decimal<2430>, daily_funding: #Decimal<90>, days_to_payoff: 27, ...}

# stress_test_prolonged_negative(rate, position_size, days, opts) -> stress map
MarginBridge.stress_test_prolonged_negative(
  Decimal.new("-0.025"),
  Decimal.new("60000"),
  90,
  periods_per_day: 24
)
#=> %{daily_cost: #Decimal<360.00000>, total_cost: #Decimal<32400.00000>, kill_switch_day: nil, ...}

# check_kill_switch(per_period_funding_rate, margin_ratio, opts) -> kill-switch map
# daily_funding_rate = per_period_rate x :periods_per_day (default 3, overridable)
MarginBridge.check_kill_switch(Decimal.new("0.015"), Decimal.new("0.145"))
#=> %{kill_switch_triggered: false, per_period_funding_rate: #Decimal<0.015>,
#     daily_funding_rate: #Decimal<0.045>, periods_per_day: #Decimal<3>, ...}
```

## `DeltaCalc.FundingProjection`

Best-, expected-, and worst-case payback horizons from funding income and volatility.
For a single-scenario timeline with optional payoff date, see `DeltaCalc.MarginBridge.payback_timeline/3`.

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

## `DeltaCalc.Pnl`

Position PnL, return-on-equity, and fee/funding-adjusted breakeven math.

```elixir
# unrealized_pnl(params) -> Decimal
Pnl.unrealized_pnl(%{
  entry_price: Decimal.new("50000"),
  mark_price: Decimal.new("51000"),
  size: Decimal.new("2"),
  side: :long
})
#=> #Decimal<2000.00000000>

# realized_pnl(params) -> Decimal (fees + accrued funding netted)
Pnl.realized_pnl(%{
  entry_price: Decimal.new("50000"),
  exit_price: Decimal.new("52000"),
  size: Decimal.new("2"),
  side: :long,
  open_fee_rate: Decimal.new("0.0004"),
  close_fee_rate: Decimal.new("0.0002"),
  accrued_funding: Decimal.new("15")
})
#=> #Decimal<...>

# roe(params) -> Decimal
Pnl.roe(%{pnl: Decimal.new("400"), margin: Decimal.new("1000")})
#=> #Decimal<40.00000000>

# breakeven(params) -> Decimal
Pnl.breakeven(%{
  entry_price: Decimal.new("50000"),
  size: Decimal.new("2"),
  open_fee_rate: Decimal.new("0.0004"),
  close_fee_rate: Decimal.new("0.0002"),
  side: :long
})
#=> #Decimal<...>
```

## `DeltaCalc.DeltaNeutral`

Net delta aggregation and rebalance sizing from exchange-supplied position deltas.

```elixir
positions = [
  %{kind: :spot, size: Decimal.new("1.5"), side: :long},
  %{kind: :perp, size: Decimal.new("1.0"), side: :short},
  %{kind: :option, delta: Decimal.new("0.35")}
]

# net_delta(positions) -> Decimal
DeltaNeutral.net_delta(positions)
#=> #Decimal<0.85000000>

# rebalance_to_neutral(positions | params) -> rebalance map
DeltaNeutral.rebalance_to_neutral(positions)
#=> %{
#     net_delta: #Decimal<0.85000000>,
#     within_tolerance: false,
#     side: :short,
#     size: #Decimal<0.85000000>,
#     instrument: :perp,
#     signed_hedge: #Decimal<-0.85000000>
#   }
```

Base-numeraire math for inverse perps, options, covered-call coverage, and risk targets:

```elixir
# base_numeraire_exposure(params) -> {:ok, Decimal} | {:error, reason}
DeltaNeutral.base_numeraire_exposure(%{
  kind: :inverse_perpetual,
  quantity: %{unit: :usd_notional, value: Decimal.new("12000")},
  mark: Decimal.new("3000")
})
#=> {:ok, #Decimal<4>}

DeltaNeutral.base_numeraire_exposure(%{
  kind: :option,
  quantity: %{unit: :base_currency, value: Decimal.new("1")},
  delta: %{semantic: :black_scholes, value: Decimal.new("0.40")},
  mark: %{unit: :quote_currency, value: Decimal.new("100"), spot_price: Decimal.new("2000")}
})
#=> {:ok, #Decimal<0.35>}   # 1 x (0.40 - 100/2000); ambiguous shapes return named errors

# settlement_coverage(params) -> {:ok, coverage map} | {:error, reason}
DeltaNeutral.settlement_coverage(%{
  eligible_base: Decimal.new("10"),
  existing_short_call_obligations: Decimal.new("2"),
  other_reservations: Decimal.new("0"),
  pending_sell_reservations: Decimal.new("0"),
  proposed_short_call_obligation: Decimal.new("5")
})
#=> {:ok, %{total_obligation: #Decimal<7>, remaining_capacity: #Decimal<3>,
#           uncovered_amount: #Decimal<0>, fully_covered: true, ...}}

# risk_target(params) -> {:ok, target map} | {:error, reason}
# Coverage never implies neutrality: fully_covered does not mean within_target.
DeltaNeutral.risk_target(%{
  base_numeraire_exposure: Decimal.new("0.65"),
  target_exposure: Decimal.new("0"),
  tolerance: Decimal.new("0.1")
})
#=> {:ok, %{residual_exposure: #Decimal<0.65>, within_target: false, ...}}
```

## `DeltaCalc.PortfolioMargin`

Combined maintenance margin, netted liquidation price, and margin usage for a position book.

```elixir
account = %{
  equity: Decimal.new("1000"),
  positions: [
    %{side: :long, quantity: Decimal.new("3"), mark_price: Decimal.new("3000"), mmr: Decimal.new("0.005")},
    %{side: :short, quantity: Decimal.new("1"), mark_price: Decimal.new("3000"), mmr: Decimal.new("0.005")}
  ]
}

# combined_maintenance_margin(account) -> Decimal
PortfolioMargin.combined_maintenance_margin(account)
#=> #Decimal<30.00000000>

# portfolio_liquidation_price(account) -> Decimal | nil
PortfolioMargin.portfolio_liquidation_price(account)
#=> #Decimal<2512.56281407>

# margin_usage(account) -> %{used, available, usage_pct}
PortfolioMargin.margin_usage(account)
#=> %{used: #Decimal<30.00000000>, available: #Decimal<970.00000000>, usage_pct: #Decimal<3.00000000>}
```

## `DeltaCalc.StressScenario`

Price-shock scenarios and cascade liquidation simulation across a portfolio-margin book.

```elixir
account = %{
  equity: Decimal.new("1000"),
  positions: [
    %{id: :btc_long, side: :long, quantity: Decimal.new("3"), mark_price: Decimal.new("3000"), mmr: Decimal.new("0.005")},
    %{id: :btc_short, side: :short, quantity: Decimal.new("1"), mark_price: Decimal.new("3000"), mmr: Decimal.new("0.005")}
  ]
}

# apply_shock(account, shock_pct) -> shock result map
StressScenario.apply_shock(account, Decimal.new("-10"))
#=> %{
#     shock_pct: #Decimal<-10>,
#     equity: #Decimal<400.00000000>,
#     positions: [...],
#     portfolio_margin: #Decimal<27.00000000>,
#     liquidation_price: #Decimal<...>
#   }

# cascade(account, shock_pct) -> cascade result map
StressScenario.cascade(account, Decimal.new("-20"))
#=> %{
#     shock_pct: #Decimal<-20>,
#     liquidated_positions: [:btc_long],
#     margin_call: #Decimal<224.00000000>,
#     survives?: true
#   }
```

## `DeltaCalc.Fees`

Effective entry/exit prices, roundtrip cost, and funding-adjusted breakeven.

```elixir
# effective_entry(fill_price, params) -> Decimal
Fees.effective_entry(Decimal.new("50000"), %{
  fee_rate: Decimal.new("0.0004"),
  slippage_bps: Decimal.new("10"),
  side: :long
})
#=> #Decimal<50070.00000000>

# effective_exit(fill_price, params) -> Decimal
Fees.effective_exit(Decimal.new("50000"), %{fee_rate: Decimal.new("0.0004"), side: :long})
#=> #Decimal<49980.00000000>

# roundtrip_cost(params) -> Decimal
Fees.roundtrip_cost(%{
  notional: Decimal.new("10000"),
  open_fee_rate: Decimal.new("0.0004"),
  close_fee_rate: Decimal.new("0.0002")
})
#=> #Decimal<6.00000000>

# funding_adjusted_breakeven(entry_price, params, accrued_funding) -> Decimal
Fees.funding_adjusted_breakeven(
  Decimal.new("50000"),
  %{size: Decimal.new("2"), open_fee_rate: Decimal.new("0.0004"), close_fee_rate: Decimal.new("0.0002"), side: :long},
  Decimal.new("0")
)
#=> #Decimal<...>
```

## `DeltaCalc.Carry`

Basis yield, break-even funding, and net carry for spot/perp hedge profitability.

```elixir
# basis(spot_price, perp_price) -> Decimal (instantaneous premium/discount, not annualized)
Carry.basis(Decimal.new("60000"), Decimal.new("60600"))
#=> #Decimal<1.00000000>

# breakeven_funding(params) -> Decimal (per-period rate)
Carry.breakeven_funding(%{
  spot_price: Decimal.new("60000"),
  perp_price: Decimal.new("60600"),
  holding_days: 30
})
#=> #Decimal<-0.00011111>

# net_carry(params) -> carry decision map
Carry.net_carry(%{
  spot_price: Decimal.new("60000"),
  perp_price: Decimal.new("60600"),
  funding_rate: Decimal.new("0.0001"),
  holding_days: 30
})
#=> %{
#     basis: #Decimal<1.00000000>,
#     basis_yield: #Decimal<1.00000000>,
#     funding_yield: #Decimal<0.90000000>,
#     net_yield: #Decimal<1.90000000>,
#     breakeven_funding: #Decimal<-0.00011111>,
#     profitable?: true
#   }
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
