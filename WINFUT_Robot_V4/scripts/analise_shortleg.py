"""v2c: long até M50+150 + short no alvo recomprando na M9. WIN 10m."""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, load_10m

df = load_10m()
print(f"{'config':>26s} {'trades':>7s} {'pts':>8s} {'PF':>6s} {'win%':>6s} {'motivos'}")
for nome, kw in [("v3 (só long, atual)", {}),
                 ("v3c (+short no alvo)", {"short_leg": True})]:
    p = Params(tgt_offset_pts=150, **kw)
    b = Backtester(df, p); b.run(); m = b.metrics()
    print(f"{nome:>26s} {m['n_trades']:>7d} {m['pnl_total_pts']:>8.0f} "
          f"{m['profit_factor']:>6.2f} {m['win_rate_%']:>6.1f} {m['saidas']}")

print("\ndetalhe dos shorts:")
b = Backtester(df, Params(tgt_offset_pts=150, short_leg=True)); b.run()
for t in b.trades:
    tag = "SHORT" if "short" in t.exit_reason else "LONG "
    print(f"  {tag} {str(t.entry_time)[:16]} entry={t.entry:.0f} exit={t.exit:.0f} "
          f"({t.exit_reason}) pnl={t.pnl_pts:+.0f}")
