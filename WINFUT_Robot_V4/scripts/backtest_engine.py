"""
backtest_engine.py — Fase 2: engine de backtest para WINFUT
================================================================================
Estratégia "Rompimento da M9 com HILO escadinha" (compra):
  CONTEXTO (setup):
    - M9 < M50 e M50 < M200            (viés de fundo baixista)
    - M9 com trajetória descendente      (M9[i-1] < M9[i-2])
    - HILO(3, adiantado 1) vermelha      (escadinha de baixa no candle anterior)
    - GAP = M50 - M9 >= min_gap_pts      (ganho potencial mínimo p/ valer a pena)
    - GAP >= min_rr * distância_à_stop   (relação risco/retorno mínima)
  GATILHO (candle i):
    - close rompe ACIMA da M9 e M9 vira ascendente (M9[i] > M9[i-1])
  EXECUÇÃO:
    - Compra a mercado na abertura do candle i+1 (sem lookahead)
    - ALVO: M50 dinâmica (sai quando o preço a alcança)
    - STOP: mínimo estrutural dos últimos `swing_lookback` candles - ATR buffer
    - DAY TRADE: sai no fechamento quando barra >= eod_time ou muda o dia
  AMBOS no mesmo candle: STOP tem prioridade (assunção conservadora)

Custos (WINFUT, 1 contrato, R$ 0,20/ponto):
  - Slippage: 1 pt por perna (mercado)
  - Corretagem: R$ 3,00 por perna (configurável)
  - Emolumentos B3: 0,0092% sobre valor financeiro (preço x 0,20)

Uso:
  python3 scripts/backtest_engine.py            # run base + sensibilidade + gráficos
"""
import json
import logging
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

import numpy as np
import pandas as pd

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("backtest")

DATA = Path(__file__).resolve().parent.parent / "data" / "winfut"
FIGS = Path(__file__).resolve().parent.parent / "docs" / "figs"

# ------------------------------------------------------------------ parâmetros
@dataclass
class Params:
    # indicadores
    fast: int = 9            # M9
    slow: int = 50           # M50
    bias: int = 200          # M200 (viés)
    hilo_n: int = 3           # HILO: média de 3 candles
    atr_n: int = 14
    # stop estrutural
    swing_lookback: int = 8          # mínimo estrutural dos últimos N candles
    stop_atr_mult: float = 0.5      # buffer abaixo do mínimo (x ATR14)
    # filtros de entrada
    min_gap_pts: float = 0.0        # gap mínimo M50-M9 em pontos
    min_rr: float = 1.0              # gap mínimo / distância até o stop
    max_ext_atr: float | None = None  # máx. que o candle gatilho pode furar acima da M9 (x ATR14). None = sem filtro
    min_room_pts: float = 0.0          # espaço mínimo restante até o alvo M50 no fechamento do gatilho
    partial_frac: float = 0.0           # v2b: fração do lote realizada ao tocar a M50; o resto corre
                                        # (0.0 = comportamento original: 100% no alvo)
    tgt_offset_pts: float = 0.0         # alvo = M50 + offset (pts). >0 captura a "furação" da M50
    short_leg: bool = False             # v2c: após o alvo do comprado, vende no alvo e
                                        # recompra na M9 (captura o retorno p/ dentro da estrutura)
    # ---- v4: short por pernada (exaustão além da M50 no regime baixista) ----
    enable_pernada_short: bool = False  # liga/desliga o módulo
    pernada_th_pts: float = 300.0        # pernada = fechamento >= M50 + 300 pts
    pernada_stop_atr: float = 0.5        # stop = máxima do gatilho + 0.5 ATR
    # gestão
    day_trade: bool = True
    eod_time: str = "17:30"
    # custos
    ponto: float = 0.20             # R$ por ponto
    slippage_pts: float = 1.0      # por perna
    corretagem: float = 3.00       # R$ por perna
    emol_pct: float = 0.000092     # 0,0092% s/ valor financeiro
    capital: float = 10_000.0
    contratos: int = 1


# ------------------------------------------------------------------ indicadores
def sma(s: pd.Series, n: int) -> pd.Series:
    return s.rolling(n, min_periods=n).mean()


def atr(df: pd.DataFrame, n: int) -> pd.Series:
    """ATR de Wilder."""
    tr = pd.concat([
        df["high"] - df["low"],
        (df["high"] - df["close"].shift(1)).abs(),
        (df["low"] - df["close"].shift(1)).abs(),
    ], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False).mean()


def hilo(df: pd.DataFrame, n: int = 3):
    """HILO escadinha: SMA(high,n) quando preço acima da linha, SMA(low,n)
    quando rompe para baixo. Retorna (serie, is_red). O '1 adiantado' é
    recurso de plotagem; aqui usamos a linha sem deslocamento."""
    hi = sma(df["high"], n)
    lo = sma(df["low"], n)
    close = df["close"].values
    line = np.full(len(df), np.nan)
    state = np.zeros(len(df), dtype=bool)  # True = vermelha (vinda das mínimas)
    prev = np.nan
    for i in range(len(df)):
        if np.isnan(hi.iloc[i]):
            continue
        if np.isnan(prev) or np.isnan(prev_line := line[i - 1]):
            line[i] = lo.iloc[i]
            state[i] = True
        elif close[i - 1] > line[i - 1]:
            line[i] = hi.iloc[i]
            state[i] = False
        else:
            line[i] = lo.iloc[i]
            state[i] = True
        prev = line[i]
    return pd.Series(line, index=df.index), pd.Series(state, index=df.index)


def resample_5m_to_10m(df5: pd.DataFrame) -> pd.DataFrame:
    """Agrupa 5m -> 10m alinhado ao pregão (bins fechados à esquerda)."""
    out = df5.resample("10min", label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"})
    out = out.dropna(subset=["open"])
    # remove bin parcial (menos de 2 barras de 5m com volume)
    return out


# ------------------------------------------------------------------ engine
@dataclass
class Trade:
    entry_time: pd.Timestamp
    exit_time: pd.Timestamp
    entry: float
    exit: float
    stop: float
    gap_entry: float        # M50-M9 no gatilho
    exit_reason: str        # alvo | stop | eod | fim_serie
    pnl_pts: float = 0.0
    pnl_brl: float = 0.0
    bars: int = 0
    # scale-out (variante v2b): parcial no alvo + runner
    partial_frac: float = 0.0     # fração realizada no alvo
    partial_price: float | None = None  # preço da parcial (M50 tocada)
    runner_price: float | None = None   # preço final do runner


class Backtester:
    def __init__(self, df: pd.DataFrame, p: Params):
        self.df = df.copy()
        self.p = p
        self._prep()

    def _prep(self):
        p = self.p
        d = self.df
        self.m9 = sma(d["close"], p.fast)
        self.m50 = sma(d["close"], p.slow)
        self.m200 = sma(d["close"], p.bias)
        self.atr14 = atr(d, p.atr_n)
        self.hilo_line, self.hilo_red = hilo(d, p.hilo_n)

    def signals(self):
        """Vetor booleano de gatilho no fechamento do candle i."""
        p = self.p
        d = self.df
        m9, m50, m200 = self.m9, self.m50, self.m200

        # contexto (avaliado no candle i; trajetória descendente = no candle anterior)
        ctx = (
            (m9 < m50) & (m50 < m200) &               # viés de fundo baixista
            (m9.shift(1) < m9.shift(2)) &             # M9 descendente antes do gatilho
            self.hilo_red.shift(1, fill_value=False)      # escadinha vermelha no setup
        )
        # gatilho: rompe M9, vira a M9 para cima E HILO reverte para verde
        trig = (
            (d["close"] > m9)
            & (m9 > m9.shift(1))
            & (m9.shift(1) < m9.shift(2))
            & (~self.hilo_red)                          # reversão: HILO verde no gatilho
        )

        gap = m50 - m9
        # distância real até o stop: (close - mínimo estrutural) + buffer ATR
        stop_dist = (d["close"] - self._swing_low()) + p.stop_atr_mult * self.atr14
        filt = (gap >= p.min_gap_pts) & (gap >= p.min_rr * stop_dist)
        # anti-esticada: candle gatilho não pode fechar longe demais da M9
        # (evita comprar repique já esticado — "candle furou para cima")
        if p.max_ext_atr is not None:
            ext = d["close"] - m9                     # quanto furou acima da M9
            filt = filt & (ext <= p.max_ext_atr * self.atr14)
        # proteção M50: se o candle JÁ fechou na/em cima da M50, o repique
        # acabou — o alvo ficaria atrás do preço de entrada. Exige espaço
        # mínimo restante até a M50 ("room") no fechamento do gatilho.
        room = (m50 + p.tgt_offset_pts) - d["close"]
        filt = filt & (room >= p.min_room_pts)
        return (ctx & trig & filt).fillna(False), gap

    def _swing_low(self) -> pd.Series:
        """Mínimo estrutural dos últimos N candles (inclusive o atual)."""
        return self.df["low"].rolling(self.p.swing_lookback, min_periods=2).min()

    def run(self):
        p = self.p
        d = self.df
        sig, gap = self.signals()
        swing = self._swing_low()
        trades: list[Trade] = []
        i = 0
        n = len(d)
        idx = d.index
        in_pos_until = -1
        eod = pd.Timestamp(p.eod_time).time()

        while i < n - 1:
            if not sig.iloc[i] or i <= in_pos_until:
                i += 1
                continue
            # ---- entrada na abertura do candle seguinte
            eb = i + 1
            entry = float(d["open"].iloc[eb]) + p.slippage_pts
            stop = float(swing.iloc[i]) - p.stop_atr_mult * float(self.atr14.iloc[i])
            g = float(gap.iloc[i])
            if np.isnan(stop) or entry <= stop:
                i += 1
                continue

            t = Trade(entry_time=idx[eb], exit_time=idx[eb], entry=entry,
                      exit=entry, stop=stop, gap_entry=g, exit_reason="fim_serie")
            frac = p.partial_frac            # 0 = original (100% no alvo)
            parcial = None                   # preço da parcial (M50 tocada)
            for j in range(eb, n):
                hi_j, lo_j = float(d["high"].iloc[j]), float(d["low"].iloc[j])
                close_j = float(d["close"].iloc[j])
                m9_j = float(self.m9.iloc[j]) if not np.isnan(self.m9.iloc[j]) else np.inf
                tgt_j = (float(self.m50.iloc[j]) + p.tgt_offset_pts
                         if not np.isnan(self.m50.iloc[j]) else np.inf)
                # conservador: stop antes do alvo no mesmo candle
                if lo_j <= stop:
                    t.exit, t.exit_reason = stop, "stop"
                elif hi_j >= tgt_j:
                    if frac <= 0:
                        t.exit, t.exit_reason = tgt_j, "alvo"
                    else:
                        # scale-out: realiza `frac` no alvo; stop sobe p/ breakeven;
                        # o runner continua enquanto o preço fechar acima da M9
                        if parcial is None:
                            parcial = tgt_j
                            stop = max(stop, entry)      # breakeven: vencedor não vira perdedor
                        if close_j < m9_j:
                            t.exit, t.exit_reason = close_j, "alvo+runner_m9"
                        elif p.day_trade and (idx[j].date() != idx[eb].date()
                                              or idx[j].time() >= eod):
                            t.exit, t.exit_reason = close_j, "alvo+runner_eod"
                        else:
                            continue
                elif parcial is not None and close_j < m9_j:
                    t.exit, t.exit_reason = close_j, "runner_m9"
                elif p.day_trade and (idx[j].date() != idx[eb].date() or idx[j].time() >= eod):
                    t.exit, t.exit_reason = float(d["close"].iloc[j]), "eod"
                else:
                    continue
                t.exit_time = idx[j]
                t.bars = j - eb + 1
                t.exit -= p.slippage_pts
                break
            # combina parcial + runner num PnL ponderado (custos idênticos aos
            # do lote cheio: são os mesmos contratos divididos em 2 saídas)
            if parcial is not None and frac > 0:
                t.partial_frac, t.partial_price = frac, parcial
                t.runner_price = t.exit
                t.pnl_pts = (frac * (parcial - entry)
                             + (1 - frac) * (t.runner_price - entry))
            else:
                t.pnl_pts = t.exit - t.entry
            # custos em R$
            fin_vol = (t.entry + t.exit) * p.ponto          # valor financeiro 2 pernas
            custos = 2 * p.corretagem + fin_vol * p.emol_pct
            t.pnl_brl = t.pnl_pts * p.ponto * p.contratos - custos
            trades.append(t)

            # ---- v2c: perna de retorno (short) após saída no alvo ----
            if p.short_leg and t.exit_reason == "alvo":
                j = idx.get_indexer([t.exit_time])[0]        # barra em que o alvo foi tocado
                entry_s = t.exit + p.slippage_pts           # vende no alvo (short)
                atr_hit = float(self.atr14.iloc[j]) if not np.isnan(self.atr14.iloc[j]) else 0.0
                stop_s = entry_s + p.stop_atr_mult * atr_hit + p.slippage_pts
                ts = Trade(entry_time=idx[j], exit_time=idx[j], entry=entry_s,
                           exit=entry_s, stop=stop_s, gap_entry=g, exit_reason="fim_serie")
                for k in range(j, n):
                    hi_k, lo_k = float(d["high"].iloc[k]), float(d["low"].iloc[k])
                    m9_k = float(self.m9.iloc[k]) if not np.isnan(self.m9.iloc[k]) else -np.inf
                    # conservador: stop antes do alvo no mesmo candle
                    if hi_k >= stop_s:
                        ts.exit, ts.exit_reason = stop_s, "stop_short"
                    elif lo_k <= m9_k:
                        ts.exit, ts.exit_reason = m9_k, "alvo_short"
                    elif p.day_trade and (idx[k].date() != idx[j].date() or idx[k].time() >= eod):
                        ts.exit, ts.exit_reason = float(d["close"].iloc[k]), "eod_short"
                    else:
                        continue
                    ts.exit_time = idx[k]
                    ts.bars = k - j + 1
                    ts.exit += p.slippage_pts          # recompra (cobre o short)
                    break
                ts.pnl_pts = ts.entry - ts.exit        # short: lucro = entrada - saída
                fin_vol = (ts.entry + ts.exit) * p.ponto
                custos = 2 * p.corretagem + fin_vol * p.emol_pct
                ts.pnl_brl = ts.pnl_pts * p.ponto * p.contratos - custos
                trades.append(ts)
                t = ts                                   # in_pos_until segue o short
            in_pos_until = idx.get_indexer([t.exit_time])[0] if t.exit_time in idx else n
            i = in_pos_until
        self.trades = trades
        return trades

    # ------------------------------------------------------------------ métricas
    def run_pernada(self):
        """v4: short por pernada — fechamento além da M50 + pernada_th_pts no regime
        M9<M50<M200 (exaustão do repique). Entra vendido no fechamento do gatilho,
        stop = máxima do gatilho + pernada_stop_atr*ATR, alvo = retorno à M50 (dinâmica),
        eod no mesmo dia. Conservador: stop antes do alvo no mesmo candle."""
        if not self.p.enable_pernada_short:
            return []
        d, p = self.df, self.p
        m9, m50, m200, atr = self.m9, self.m50, self.m200, self.atr14
        ctx = (m9 < m50) & (m50 < m200)
        ext = (d["close"] - m50).where(ctx)
        idx = d.index
        n = len(d)
        eod = pd.Timestamp(p.eod_time).time()
        trades = []
        for j in range(n):
            e = float(ext.iloc[j]) if not np.isnan(ext.iloc[j]) else 0.0
            if e < p.pernada_th_pts:
                continue
            # evento único: pula se a barra anterior também foi pernada
            if j > 0 and not np.isnan(ext.iloc[j-1]) and float(ext.iloc[j-1]) >= p.pernada_th_pts:
                continue
            entry = float(d["close"].iloc[j]) + p.slippage_pts     # vende no fechamento
            stop = float(d["high"].iloc[j]) + p.pernada_stop_atr * float(atr.iloc[j])
            t = Trade(entry_time=idx[j], exit_time=idx[j], entry=entry,
                      exit=entry, stop=stop, gap_entry=e, exit_reason="fim_serie")
            for k in range(j, n):
                if idx[k].date() != idx[j].date() or idx[k].time() >= eod:
                    t.exit, t.exit_reason = float(d["close"].iloc[min(k, n-1)]), "eod_short"
                elif float(d["high"].iloc[k]) >= stop:
                    t.exit, t.exit_reason = stop + p.slippage_pts, "stop_pernada"
                elif float(d["low"].iloc[k]) <= float(m50.iloc[k]):
                    t.exit, t.exit_reason = float(m50.iloc[k]) - p.slippage_pts, "alvo_pernada"
                else:
                    continue
                t.exit_time = idx[k]
                t.bars = k - j + 1
                break
            t.pnl_pts = t.entry - t.exit            # short: lucro = entrada - saída
            fin_vol = (t.entry + t.exit) * p.ponto
            custos = 2 * p.corretagem + fin_vol * p.emol_pct
            t.pnl_brl = t.pnl_pts * p.ponto * p.contratos - custos
            trades.append(t)
            j = k                                            # continua após a saída
        return trades

    def metrics(self) -> dict:
        p = self.p
        ts = pd.DataFrame([asdict(t) for t in self.trades])
        if ts.empty:
            return {"erro": "sem trades"}
        ts["exit_day"] = pd.to_datetime(ts["exit_time"]).dt.date

        wins = ts[ts.pnl_pts > 0]
        losses = ts[ts.pnl_pts <= 0]
        equity = p.capital + ts.pnl_brl.cumsum()
        peak = equity.cummax()
        dd = equity - peak
        mdd_brl = abs(dd.min())
        mdd_pct = mdd_brl / peak.max() * 100

        # retornos diários (day trade: PnL do dia / capital)
        daily = ts.groupby("exit_day").pnl_brl.sum()
        dias = (pd.to_datetime(ts.exit_time.iloc[-1]) - pd.to_datetime(ts.entry_time.iloc[0])).days
        daily_ret = daily / p.capital
        sharpe = (daily_ret.mean() / daily_ret.std() * np.sqrt(252)
                  if daily_ret.std() > 0 else np.nan)

        tot_pts = ts.pnl_pts.sum()
        retorno_total = (equity.iloc[-1] - p.capital) / p.capital * 100
        anos = max(dias / 252, 1 / 252)
        ret_anual = ((equity.iloc[-1] / p.capital) ** (1 / anos) - 1) * 100

        # sequência de perdas
        sign = (ts.pnl_pts > 0).astype(int).values
        max_seq = cur = 0
        for s in sign:
            cur = cur + 1 if s == 0 else 0
            max_seq = max(max_seq, cur)

        m = {
            "periodo": f"{ts.entry_time.iloc[0]:%d/%m/%Y} a {ts.exit_time.iloc[-1]:%d/%m/%Y}",
            "barras_testadas": len(self.df),
            "n_trades": len(ts),
            "win_rate_%": round(len(wins) / len(ts) * 100, 1),
            "pnl_total_pts": round(tot_pts, 0),
            "pnl_total_R$": round(ts.pnl_brl.sum(), 2),
            "retorno_%_capital": round(retorno_total, 2),
            "retorno_anualizado_%": round(ret_anual, 1),
            "ganho_medio_pts": round(wins.pnl_pts.mean(), 1) if len(wins) else 0,
            "perda_media_pts": round(losses.pnl_pts.mean(), 1) if len(losses) else 0,
            "payoff": round(wins.pnl_pts.mean() / abs(losses.pnl_pts.mean()), 2)
                      if len(wins) and len(losses) else np.nan,
            "profit_factor": round(wins.pnl_pts.sum() / abs(losses.pnl_pts.sum()), 2)
                             if len(losses) and losses.pnl_pts.sum() != 0 else np.inf,
            "expectancia_pts/trade": round(ts.pnl_pts.mean(), 1),
            "max_drawdown_R$": round(mdd_brl, 2),
            "max_drawdown_%": round(mdd_pct, 1),
            "sharpe_diario": round(float(sharpe), 2) if not np.isnan(sharpe) else None,
            "calmar": round(ret_anual / mdd_pct, 2) if mdd_pct > 0 else None,
            "duracao_media_barras": round(ts.bars.mean(), 1),
            "max_perdas_seguidas": max_seq,
            "gap_medio_entrada_pts": round(ts.gap_entry.mean(), 0),
            "saidas": ts.exit_reason.value_counts().to_dict(),
        }
        self.ts, self.equity = ts, equity
        return m

    # ------------------------------------------------------------------ gráficos
    def plot(self, prefix: str = "bt"):
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        FIGS.mkdir(parents=True, exist_ok=True)
        ts, eq, p = self.ts, self.equity, self.p

        # 1) equity + drawdown
        fig, ax = plt.subplots(2, 1, figsize=(10, 6), sharex=True,
                               gridspec_kw={"height_ratios": [3, 1]})
        x = range(len(eq))
        ax[0].plot(x, eq.values, color="#0b6e4f", lw=1.6)
        ax[0].axhline(p.capital, color="gray", ls=":", lw=0.8)
        ax[0].set_title("Curva de capital (R$) — 1 contrato WINFUT")
        dd = eq - eq.cummax()
        ax[1].fill_between(x, dd.values, 0, color="#b23a48", alpha=0.7)
        ax[1].set_title("Drawdown (R$)")
        plt.tight_layout()
        f1 = FIGS / f"{prefix}_equity.png"
        plt.savefig(f1, dpi=110); plt.close()

        # 2) histograma PnL por trade
        fig, ax = plt.subplots(figsize=(8, 4))
        ax.hist(ts.pnl_pts, bins=30, color="#14532d", edgecolor="white")
        ax.axvline(0, color="#b23a48", lw=1)
        ax.set_title("Distribuição do resultado por trade (pontos)")
        plt.tight_layout()
        f2 = FIGS / f"{prefix}_pnl_hist.png"
        plt.savefig(f2, dpi=110); plt.close()

        # 3) gap na entrada vs resultado
        fig, ax = plt.subplots(figsize=(7, 4))
        cores = np.where(ts.pnl_pts > 0, "#0b6e4f", "#b23a48")
        ax.scatter(ts.gap_entry, ts.pnl_pts, c=cores, s=28, alpha=0.75)
        ax.axhline(0, color="gray", lw=0.8)
        ax.set_xlabel("Gap M50-M9 na entrada (pts)")
        ax.set_ylabel("Resultado do trade (pts)")
        ax.set_title("Gap de ganho potencial x resultado")
        plt.tight_layout()
        f3 = FIGS / f"{prefix}_gap_scatter.png"
        plt.savefig(f3, dpi=110); plt.close()
        return [f1, f2, f3]


def load_10m() -> pd.DataFrame:
    """WINFUT 10m: reagrupa a série de 5m (TV não serve 10m p/ anônimo)."""
    df5 = pd.read_parquet(DATA / "intraday" / "winfut_5m.parquet")
    return resample_5m_to_10m(df5)


def load_15m() -> pd.DataFrame:
    return pd.read_parquet(DATA / "intraday" / "winfut_15m.parquet")


def sensitivity(df: pd.DataFrame, base: Params) -> pd.DataFrame:
    """Mini-grid anti-overfitting: min_gap x stop_atr_mult."""
    rows = []
    for gap in [0, 100, 200, 300]:
        for mult in [0.25, 0.5, 1.0]:
            p = Params(**{**asdict(base), "min_gap_pts": gap, "stop_atr_mult": mult})
            bt = Backtester(df, p)
            bt.run()
            m = bt.metrics()
            rows.append({"min_gap": gap, "atr_mult": mult,
                         "trades": m.get("n_trades", 0),
                         "pts": m.get("pnl_total_pts", 0),
                         "win%": m.get("win_rate_%", 0),
                         "PF": m.get("profit_factor", np.nan)})
    return pd.DataFrame(rows)


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "10m"
    if which == "10m":
        df = load_10m()
    else:
        df = load_15m()
    log.info("Base %s: %d barras de %s a %s", which, len(df), df.index[0], df.index[-1])

    p = Params()
    bt = Backtester(df, p)
    bt.run()
    m = bt.metrics()
    print("\n===== RESULTADO BASE (%s) =====" % which)
    for k, v in m.items():
        print(f"{k:26s}: {v}")

    figs = bt.plot(f"winfut_{which}")
    print("\ngráficos:", [str(f) for f in figs])

    print("\n===== SENSIBILIDADE (anti-overfitting) =====")
    print(sensitivity(df, p).to_string(index=False))

    bt.ts.to_csv(DATA / f"trades_winfut_{which}.csv", index=False)
