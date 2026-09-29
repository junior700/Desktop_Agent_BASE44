"""Alvo = M50 + offset. Até onde dá pra esticar a furação? (WIN 10m, v2)"""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, load_10m

df = load_10m()
print(f"{'offset':>7s} {'trades':>7s} {'pts':>8s} {'win%':>6s} {'PF':>6s} {'payoff':>7s} {'motivos'}")
for off in [0, 50, 100, 150, 200, 250, 300]:
    p = Params(tgt_offset_pts=off)
    b = Backtester(df, p); b.run(); m = b.metrics()
    if "erro" in m:
        print(f"{off:7d} sem trades"); continue
    print(f"{off:7d} {m['n_trades']:>7d} {m['pnl_total_pts']:>8.0f} {m['win_rate_%']:>6.1f} "
          f"{m['profit_factor']:>6.2f} {m['payoff']:>7.2f} {m['saidas']}")

print("\ndetalhe com offset=150:")
b = Backtester(df, Params(tgt_offset_pts=150)); b.run()
for t in b.trades:
    print(f"  {str(t.entry_time)[:16]} entry={t.entry:.0f} exit={t.exit:.0f} "
          f"({t.exit_reason}) pnl={t.pnl_pts:+.0f}")
