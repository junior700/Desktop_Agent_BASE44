"""Roda a estratégia HILO escadinha v2 no WDO 10m (resample do 5m) + sensibilidade."""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, resample_5m_to_10m, sensitivity, asdict
import pandas as pd

df5 = pd.read_parquet("data/wdofut/intraday/wdofut_5m.parquet")
df = resample_5m_to_10m(df5)
print(f"Base WDO 10m: {len(df)} barras de {df.index[0]} a {df.index[-1]}")

# custos WDO: ponto R$10, emol. day trade 0,0077%, slippage 0,5 pt/perna
p = Params(ponto=10.0, slippage_pts=0.5, emol_pct=0.000077)
bt = Backtester(df, p)
bt.run()
m = bt.metrics()
print("\n===== WDO 10m — HILO escadinha v2 =====")
for k, v in m.items():
    print(f"{k:26s}: {v}")
if "erro" not in m:
    figs = bt.plot("wdofut_10m")
    bt.ts.to_csv("data/wdofut/trades_wdofut_10m.csv", index=False)

print("\n===== SENSIBILIDADE (WDO 10m) =====")
print(sensitivity(df, p).to_string(index=False))
