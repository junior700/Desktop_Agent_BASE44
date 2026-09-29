"""
Revalidação completa da v2 com alvo M50+150 (config atual do robô).
Gera: métricas, sensibilidade de parâmetros, Monte Carlo, checagem 15m,
gráficos (equity, drawdown, distribuição, heatmap de sensibilidade).
Saída em reports/validacao_v3/.
"""
import sys, json, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from backtest_engine import Backtester, Params, load_10m

from backtest_engine import Backtester, Params

OUT = os.path.join(os.path.dirname(__file__), "..", "reports", "validacao_v3")
os.makedirs(OUT, exist_ok=True)
RNG = np.random.default_rng(42)

# ------------------------------------------------------------------ 1. backtest base
df = load_10m()
p = Params(**json.load(open(os.path.join(os.path.dirname(__file__), "bot_config.json")))["params"])
bt = Backtester(df, p)
bt.run()
m = bt.metrics()

trades = pd.DataFrame([t.__dict__ for t in bt.trades])
trades["data"] = pd.to_datetime(trades["entry_time"]).dt.date

# ------------------------------------------------------------------ 2. sensibilidade (robustez, não otimização)
sens_off, sens_stop = [], []
for off in [0, 50, 100, 150, 200, 250, 300]:
    b = Backtester(df, Params(**{**p.__dict__, "tgt_offset_pts": off})); b.run()
    mm = b.metrics()
    sens_off.append({"offset_alvo": off, "trades": mm.get("n_trades"),
                     "pts": mm.get("pnl_total_pts"), "PF": mm.get("profit_factor"),
                     "win%": mm.get("win_rate_%")})
for mult in [0.0, 0.25, 0.5, 0.75, 1.0]:
    b = Backtester(df, Params(**{**p.__dict__, "stop_atr_mult": mult})); b.run()
    mm = b.metrics()
    sens_stop.append({"stop_xATR": mult, "trades": mm.get("n_trades"),
                      "pts": mm.get("pnl_total_pts"), "PF": mm.get("profit_factor"),
                      "win%": mm.get("win_rate_%")})

# matriz offset x stop (heatmap de PF)
offs = [0, 100, 150, 200, 300]
mults = [0.0, 0.5, 1.0]
grid = np.zeros((len(mults), len(offs)))
for a, mult in enumerate(mults):
    for o, off in enumerate(offs):
        b = Backtester(df, Params(**{**p.__dict__, "tgt_offset_pts": off, "stop_atr_mult": mult}))
        b.run()
        mm = b.metrics()
        grid[a, o] = mm.get("profit_factor", 0 if "erro" in mm else 0)

# ------------------------------------------------------------------ 3. Monte Carlo (bootstrap dos trades)
pnl = trades["pnl_pts"].values
N_SIM, HORIZON = 10_000, 20
totais = np.zeros(N_SIM)
mdds = np.zeros(N_SIM)
neg50 = 0  # prob. de PnL negativo em 20 trades
for s in range(N_SIM):
    sample = RNG.choice(pnl, size=HORIZON, replace=True)
    eq = np.cumsum(sample)
    totais[s] = eq[-1]
    mdds[s] = (eq - np.maximum.accumulate(eq)).min()
neg50 = (totais < 0).mean() * 100
mc = {
    "horizonte_trades": HORIZON,
    "simulacoes": N_SIM,
    "pnl_mediana_pts": float(np.median(totais)),
    "pnl_p5_pts": float(np.percentile(totais, 5)),
    "pnl_p95_pts": float(np.percentile(totais, 95)),
    "prob_pnl_negativo_%": float(neg50),
    "drawdown_mediano_pts": float(np.median(mdds)),
    "drawdown_pior_caso_p95_pts": float(np.percentile(mdds, 5)),
}

# ------------------------------------------------------------------ 4. checagem 15m (coerência em outro timeframe)
try:
    from backtest_engine import load_15m as _l15
except Exception:
    _l15 = None
if _l15 is None:
    # fallback: carregar parquet 15m e rodar mesma engine
    d15 = pd.read_parquet(os.path.join(os.path.dirname(__file__), "..", "data", "winfut", "intraday", "winfut_15m.parquet"))
    d15.index = pd.to_datetime(d15.index)
    b15 = Backtester(d15, Params(**{**p.__dict__, "fast": 9, "slow": 50}))
    b15.run()
    m15 = b15.metrics()
else:
    b15 = Backtester(_l15(), Params(**{**p.__dict__}))
    b15.run()
    m15 = b15.metrics()

# ------------------------------------------------------------------ 5. gráficos
fig, ax = plt.subplots(2, 1, figsize=(9, 7), sharex=True)
eq_pts = trades["pnl_pts"].cumsum()
dates = pd.to_datetime(trades["entry_time"])
ax[0].step(dates, eq_pts, where="post", color="#0b6e4f", lw=2, marker="o")
ax[0].set_title("v2 + alvo M50+150 — curva de capital (pts)")
ax[0].axhline(0, color="#999", lw=0.8)
ax[0].grid(alpha=0.3)
run_max = eq_pts.cummax()
ax[1].fill_between(dates, (eq_pts - run_max), 0, color="#c0392b", alpha=0.5)
ax[1].set_title("Drawdown (pts)")
ax[1].grid(alpha=0.3)
plt.tight_layout()
plt.savefig(os.path.join(OUT, "equity_v3.png"), dpi=120)

fig, ax = plt.subplots(1, 2, figsize=(11, 4))
ax[0].hist(totais, bins=60, color="#0b6e4f", alpha=0.8)
ax[0].axvline(0, color="#c0392b", lw=1.5)
ax[0].set_title(f"Monte Carlo: PnL em {HORIZON} trades (10k sims)")
ax[0].set_xlabel("pts")
ax[1].hist(mdds, bins=60, color="#c0392b", alpha=0.8)
ax[1].set_title("Drawdown simulado (pts)")
plt.tight_layout()
plt.savefig(os.path.join(OUT, "montecarlo_v3.png"), dpi=120)

fig, ax = plt.subplots(figsize=(6, 3.5))
im = ax.imshow(grid, cmap="RdYlGn", aspect="auto")
ax.set_xticks(range(len(offs)), [str(o) for o in offs])
ax.set_yticks(range(len(mults)), [str(m) for m in mults])
ax.set_xlabel("Offset do alvo (pts acima da M50)")
ax.set_ylabel("Stop (x ATR)")
ax.set_title("Profit Factor — offset x stop")
for a in range(len(mults)):
    for o in range(len(offs)):
        ax.text(o, a, f"{grid[a, o]:.2f}", ha="center", va="center", fontsize=9)
plt.colorbar(im)
plt.tight_layout()
plt.savefig(os.path.join(OUT, "sensibilidade_v3.png"), dpi=120)

# ------------------------------------------------------------------ 6. relatório
rep = {
    "config": {k: v for k, v in p.__dict__.items()},
    "metricas": m,
    "sensibilidade_offset": sens_off,
    "sensibilidade_stop": sens_stop,
    "monte_carlo": mc,
    "checagem_15m": {k: m15.get(k) for k in ["n_trades", "pnl_total_pts", "profit_factor", "win_rate_%"]},
    "trades": trades[["entry_time", "entry", "exit", "exit_reason", "pnl_pts"]].assign(
        entry_time=lambda x: x.entry_time.astype(str)).to_dict("records"),
}
json.dump(rep, open(os.path.join(OUT, "metricas_v3.json"), "w"), indent=2, default=str)

lines = [f"# Validação v3 — alvo M50+{p.tgt_offset_pts:.0f} pts (WIN 10m)", "",
    f"**Período:** {m['periodo']} | **Trades:** {m['n_trades']} | **Barras:** {m['barras_testadas']}", "",
    "## Métricas", f"| Métrica | Valor |", "|---|---|"]
for k in ["pnl_total_pts", "pnl_total_R$", "retorno_%_capital", "retorno_anualizado_%",
          "win_rate_%", "payoff", "profit_factor", "expectancia_pts/trade",
          "max_drawdown_R$", "max_drawdown_%", "sharpe_diario", "calmar",
          "max_perdas_seguidas", "duracao_media_barras"]:
    lines.append(f"| {k} | {m[k]} |")
lines += ["", "## Sensibilidade — offset do alvo", "| offset | trades | pts | PF | win% |", "|---|---|---|---|---|"]
for r in sens_off:
    lines.append(f"| {r['offset_alvo']} | {r['trades']} | {r['pts']} | {r['PF']} | {r['win%']} |")
lines += ["", "## Sensibilidade — stop (x ATR)", "| stop | trades | pts | PF | win% |", "|---|---|---|---|---|"]
for r in sens_stop:
    lines.append(f"| {r['stop_xATR']} | {r['trades']} | {r['pts']} | {r['PF']} | {r['win%']} |")
lines += ["", "## Monte Carlo (bootstrap, 20 trades à frente)", ""]
for k, v in mc.items():
    lines.append(f"- **{k}:** {v}")
lines += ["", "## Checagem de coerência no 15m", "",
    f"n_trades: {m15.get('n_trades')} | pts: {m15.get('pnl_total_pts')} | "
    f"PF: {m15.get('profit_factor')} | win%: {m15.get('win_rate_%')}", "",
    "## Aviso metodológico",
    "Amostra de 4 trades: métricas (Sharpe/Calmar especialmente) são instatísticas. "
    "Sensibilidade serve para checar estabilidade, não para otimizar. "
    "Validação definitiva exige a amostra do paper trading em execução.", ""]
open(os.path.join(OUT, "relatorio_v3.md"), "w").write("\n".join(lines))
print("OK ->", os.path.abspath(OUT))
