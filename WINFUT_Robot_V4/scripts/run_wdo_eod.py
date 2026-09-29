"""Varre horário de saída EOD no WDO 10m (estratégia v2)."""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, resample_5m_to_10m
import pandas as pd

df5 = pd.read_parquet("data/wdofut/intraday/wdofut_5m.parquet")
df = resample_5m_to_10m(df5)

print(f"{'eod':>6s} {'trades':>7s} {'pts':>8s} {'win%':>6s} {'PF':>6s} {'alvo':>5s} {'stop':>5s} {'eod':>4s}")
rows = []
for eod in ["17:30", "17:00", "16:55", "16:30", "16:00", "15:30", "15:00"]:
    p = Params(ponto=10.0, slippage_pts=0.5, emol_pct=0.000077, eod_time=eod)
    bt = Backtester(df, p)
    bt.run()
    m = bt.metrics()
    if "erro" in m:
        print(f"{eod:>6s} sem trades"); continue
    s = m["saidas"]
    print(f"{eod:>6s} {m['n_trades']:>7d} {m['pnl_total_pts']:>8.0f} {m['win_rate_%']:>6.1f} "
          f"{m['profit_factor']:>6.2f} {s.get('alvo',0):>5d} {s.get('stop',0):>5d} {s.get('eod',0):>4d}")
    rows.append((eod, bt, m))

# detalhe do melhor
best = max(rows, key=lambda r: r[2]["pnl_total_pts"])
print(f"\n=== DETALHE: saída {best[0]} ===")
for k, v in best[2].items():
    print(f"{k:26s}: {v}")
best[1].plot("wdofut_10m_eod" + best[0].replace(":", ""))
best[1].ts.to_csv("data/wdofut/trades_wdofut_10m.csv", index=False)
