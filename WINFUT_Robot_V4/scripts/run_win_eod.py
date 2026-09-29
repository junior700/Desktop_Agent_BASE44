"""Varre horário de saída EOD no WIN 10m (v2) p/ comparar com WDO."""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, load_10m

df = load_10m()
print(f"{'eod':>6s} {'trades':>7s} {'pts':>8s} {'win%':>6s} {'PF':>6s} {'alvo':>5s} {'stop':>5s} {'eod':>4s}")
for eod in ["17:30", "17:00", "16:55", "16:30", "16:00", "15:30", "15:00", "14:00"]:
    p = Params(eod_time=eod)
    bt = Backtester(df, p)
    bt.run()
    m = bt.metrics()
    if "erro" in m:
        print(f"{eod:>6s} sem trades"); continue
    s = m["saidas"]
    print(f"{eod:>6s} {m['n_trades']:>7d} {m['pnl_total_pts']:>8.0f} {m['win_rate_%']:>6.1f} "
          f"{m['profit_factor']:>6.2f} {s.get('alvo',0):>5d} {s.get('stop',0):>5d} {s.get('eod',0):>4d}")
