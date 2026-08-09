defmodule DeltaCalc.StressScenario do
  @moduledoc """
  Price-shock scenario engine for a portfolio-margin position book.

  Applies signed mark-price moves, evaluates per-position margin and liquidation
  under the netted book model, and simulates cascade liquidations when equity
  falls below maintenance margin. All margin and liquidation math delegates to
  `DeltaCalc.PortfolioMargin`.
  """

  use Descripex, namespace: "/stress_scenario"

  alias DeltaCalc.{Calc, PortfolioMargin}
  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)
  @one Decimal.new(1)
  @hundred Decimal.new(100)

  @typedoc "Portfolio-margin position input, with optional caller-supplied identifier."
  @type position ::
          PortfolioMargin.position() | %{optional(:id) => term(), optional(:symbol) => term()}

  @typedoc "Account inputs for stress scenarios."
  @type account :: %{
          required(:equity) => DecimalInput.input(),
          required(:positions) => [position()]
        }

  @typedoc "Per-position state after a price shock."
  @type shocked_position :: %{
          id: term(),
          side: PortfolioMargin.side(),
          quantity: Decimal.t(),
          mark_price: Decimal.t(),
          margin: Decimal.t()
        }

  @typedoc "Result of applying a uniform price shock to the book."
  @type shock_result :: %{
          shock_pct: Decimal.t(),
          equity: Decimal.t(),
          positions: [shocked_position()],
          portfolio_margin: Decimal.t(),
          liquidation_price: Decimal.t() | nil,
          portfolio_liquidated?: boolean()
        }

  @typedoc "Cascade liquidation outcome under a price shock."
  @type cascade_result :: %{
          shock_pct: Decimal.t(),
          liquidated_positions: [term()],
          margin_call: Decimal.t(),
          survives?: boolean()
        }

  api(
    :apply_shock,
    "Apply a signed uniform price-move percentage and return per-position post-shock state.",
    params: [
      account: [
        kind: :value,
        description:
          "Map with :equity and position :quantity, :mark_price, and :mmr as canonical decimal strings; each position also has :side and optional string :id or :symbol. Native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: %{
          equity: String.t(),
          positions: [
            %{
              optional(:id) => String.t(),
              optional(:symbol) => String.t(),
              side: :long | :short,
              quantity: String.t(),
              mark_price: String.t(),
              mmr: String.t()
            }
          ]
        }
      ],
      shock_pct: [
        kind: :value,
        description:
          "Signed price move in percent as a canonical decimal string (negative = price down, positive = price up); native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :shock_pct, shocked :equity, per-position :positions (:margin), " <>
          ":portfolio_margin, :liquidation_price from portfolio-margin netting, and " <>
          "book-wide :portfolio_liquidated?."
    }
  )

  @doc "Return post-shock equity and per-position margin plus portfolio liquidation status."
  @spec apply_shock(account(), DecimalInput.input()) :: shock_result()
  def apply_shock(account, shock_pct) do
    shock = DecimalInput.cast!(shock_pct)
    shocked_account = shocked_account(account, shock)
    portfolio_liquidated? = portfolio_liquidated?(shocked_account)

    positions =
      account.positions
      |> Enum.with_index()
      |> Enum.map(fn {position, index} ->
        shocked_mark = shocked_mark_price(position.mark_price, shock)

        %{
          id: position_id(position, index),
          side: position.side,
          quantity: DecimalInput.cast!(position.quantity),
          mark_price: shocked_mark,
          margin: position_margin(position, shocked_mark)
        }
      end)

    %{
      shock_pct: shock,
      equity: shocked_account.equity,
      positions: positions,
      portfolio_margin: PortfolioMargin.combined_maintenance_margin(shocked_account),
      liquidation_price: PortfolioMargin.portfolio_liquidation_price(shocked_account),
      portfolio_liquidated?: portfolio_liquidated?
    }
  end

  api(
    :cascade,
    "Simulate cascade liquidations under a price shock until the book stabilizes or is flat.",
    params: [
      account: [
        kind: :value,
        description:
          "Map with :equity and position :quantity, :mark_price, and :mmr as canonical decimal strings; each position also has :side and optional string :id or :symbol. Native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: %{
          equity: String.t(),
          positions: [
            %{
              optional(:id) => String.t(),
              optional(:symbol) => String.t(),
              side: :long | :short,
              quantity: String.t(),
              mark_price: String.t(),
              mmr: String.t()
            }
          ]
        }
      ],
      shock_pct: [
        kind: :value,
        description:
          "Signed price move in percent as a canonical decimal string applied uniformly to every mark price; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :shock_pct, :liquidated_positions (ids removed in cascade order), " <>
          ":margin_call (initial shortfall), and :survives? after simulated liquidations."
    }
  )

  @doc "Liquidate positions iteratively when shocked equity is below maintenance margin."
  @spec cascade(account(), DecimalInput.input()) :: cascade_result()
  def cascade(account, shock_pct) do
    shock = DecimalInput.cast!(shock_pct)
    initial = shocked_account(account, shock)
    margin_call = margin_call(initial)

    {liquidated_positions, final_account} =
      cascade_positions(account, shock, [])

    final = shocked_account(final_account, shock)

    %{
      shock_pct: shock,
      liquidated_positions: liquidated_positions,
      margin_call: margin_call,
      survives?: portfolio_survives?(final)
    }
  end

  defp cascade_positions(account, shock, liquidated) do
    shocked = shocked_account(account, shock)

    cond do
      portfolio_survives?(shocked) ->
        {Enum.reverse(liquidated), account}

      account.positions == [] ->
        {Enum.reverse(liquidated), account}

      true ->
        {position, index} = highest_margin_position(account, shock)
        id = position_id(position, index)

        {prefix, [_position | suffix]} = Enum.split(account.positions, index)

        remaining = %{
          account
          | equity: realized_equity(account, position, shock),
            positions: prefix ++ suffix
        }

        cascade_positions(remaining, shock, [id | liquidated])
    end
  end

  defp highest_margin_position(account, shock) do
    account.positions
    |> Enum.with_index()
    |> Enum.max_by(fn {position, _index} ->
      shocked_mark = shocked_mark_price(position.mark_price, shock)
      position_margin(position, shocked_mark)
    end)
  end

  defp shocked_account(account, shock) do
    shocked_positions =
      Enum.map(account.positions, fn position ->
        %{position | mark_price: shocked_mark_price(position.mark_price, shock)}
      end)

    %{
      equity: shocked_equity(account, shock),
      positions: shocked_positions
    }
  end

  defp shocked_equity(account, shock) do
    pnl =
      Enum.reduce(account.positions, @zero, fn position, acc ->
        Decimal.add(acc, position_pnl(position, shock))
      end)

    account.equity
    |> DecimalInput.cast!()
    |> Decimal.add(pnl)
    |> Calc.quantize()
  end

  defp realized_equity(account, position, shock) do
    account.equity
    |> DecimalInput.cast!()
    |> Decimal.add(position_pnl(position, shock))
    |> Calc.quantize()
  end

  defp position_pnl(position, shock) do
    quantity = DecimalInput.cast!(position.quantity)
    mark = DecimalInput.cast!(position.mark_price)
    shocked_mark = shocked_mark_price(mark, shock)

    signed =
      case position.side do
        :long -> quantity
        :short -> Decimal.negate(quantity)
      end

    shocked_mark
    |> Decimal.sub(mark)
    |> Decimal.mult(signed)
  end

  defp shocked_mark_price(mark_price, shock_pct) do
    mark_price
    |> DecimalInput.cast!()
    |> Decimal.mult(
      shock_pct
      |> Decimal.div(@hundred)
      |> Decimal.add(@one)
    )
    |> Calc.quantize()
  end

  defp position_margin(position, mark_price) do
    position.quantity
    |> DecimalInput.cast!()
    |> Decimal.abs()
    |> Decimal.mult(mark_price)
    |> Decimal.mult(DecimalInput.cast!(position.mmr))
    |> Calc.quantize()
  end

  defp portfolio_liquidated?(account) do
    not portfolio_survives?(account)
  end

  defp portfolio_survives?(account) do
    equity = DecimalInput.cast!(account.equity)
    maintenance = PortfolioMargin.combined_maintenance_margin(account)

    Decimal.compare(equity, maintenance) != :lt
  end

  defp margin_call(account) do
    equity = DecimalInput.cast!(account.equity)
    maintenance = PortfolioMargin.combined_maintenance_margin(account)
    shortfall = Decimal.sub(maintenance, equity)

    case Decimal.compare(shortfall, @zero) do
      :gt -> Calc.quantize(shortfall)
      _ -> @zero
    end
  end

  defp position_id(position, index) do
    cond do
      Map.has_key?(position, :id) -> Map.fetch!(position, :id)
      Map.has_key?(position, :symbol) -> Map.fetch!(position, :symbol)
      true -> index
    end
  end
end
