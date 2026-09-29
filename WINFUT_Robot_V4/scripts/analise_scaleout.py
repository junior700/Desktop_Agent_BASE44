"""Variante v2b: scale-out — parcial na M50 + runner (WIN 10m)."""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, load_10m

df = load_10m()
print(f"{'frac':>6s} {'trades':>7s} {'pts':>8s} {'win%':>6s} {'PF':>6s} {'payoff':>7s} {'motivos':s}")
for f in [0.0, 0.25, 0.50, 0.75]:
    p = Params(partial_frac=f)
    b = Backtester(df, p); b.run(); m = b.metrics()
    if "erro" in m:
        print(f"{f:6.2f} sem trades"); continue
    print(f"{f:6.2f} {m['n_trades']:>7d} {m['pnl_total_pts']:>8.0f} {m['win_rate_%']:>6.1f} "
          f"{m['profit_factor']:>6.2f} {m['payoff']:>7.2f} {m['saidas']}")
b = Backtester(df, Params(partial_frac=0.5)); b.run()
for t in b.trades:
    par = f"parcial@{t.partial_price:.0f} runner@{t.runner_price:.0f}" if t.partial_price else ""
    print(f"  {str(t.entry_time)[:16]} exit={t.exit:.0f} ({t.exit_reason}) {par} pnl={t.pnl_pts:+.0f}")
