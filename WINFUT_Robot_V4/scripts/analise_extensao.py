"""Testa proteções do candle gatilho: furação da M9 (ext) e da M50 (room)."""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, load_10m

df = load_10m()
print("=== candle gatilho x M50 (sala restante até o alvo) ===")
bt = Backtester(df, Params())
sig, gap = bt.signals()
for i in df.index[sig]:
    close = float(df.loc[i, "close"]); m50 = float(bt.m50.loc[i])
    r = m50 - close
    print(f"{str(i)[:16]} close={close:.0f} M50={m50:.0f} room={r:+.0f} pts "
          f"{'⚠️ FURADA da M50' if r <= 0 else ''}")

print("\n=== combos filtro na v2 (4 trades) ===")
print(f"{'k_ext':>6s} {'room_pts':>9s} {'trades':>7s} {'pts':>8s} {'PF':>6s}")
for k, room in [(None, 0.0), (1.0, 0.0), (None, 200.0), (1.0, 200.0)]:
    p = Params(max_ext_atr=k, min_room_pts=room)
    b = Backtester(df, p); b.run(); m = b.metrics()
    if "erro" in m:
        print(f"{str(k):>6s} {room:9.0f} sem trades"); continue
    print(f"{str(k):>6s} {room:9.0f} {m['n_trades']:>7d} {m['pnl_total_pts']:>8.0f} {m['profit_factor']:>6.2f}")
