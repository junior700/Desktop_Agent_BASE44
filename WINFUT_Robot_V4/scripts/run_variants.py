"""Roda a mesma lógica em 15m (6 meses) e diário (20 anos) p/ validação estrutural."""
import sys
sys.path.insert(0, "scripts")
from backtest_engine import Backtester, Params, load_10m, load_15m, DATA
import pandas as pd

for nome, loader, p in [
    ("15m", load_15m, Params(day_trade=True)),
    ("diario", lambda: pd.read_parquet(DATA / "daily" / "winfut_daily.parquet"),
     Params(day_trade=False)),
]:
    df = loader()
    bt = Backtester(df, p)
    bt.run()
    m = bt.metrics()
    print(f"\n===== {nome} ({len(df)} barras) =====")
    for k, v in m.items():
        print(f"{k:26s}: {v}")
    if "erro" not in m:
        bt.plot(f"winfut_{nome}")
