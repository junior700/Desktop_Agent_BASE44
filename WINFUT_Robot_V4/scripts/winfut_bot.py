"""
winfut_bot.py — Fase 3: Robot de PAPER TRADING da estratégia HILO Escadinha v2
================================================================================
Estratégia: mesma da engine de backtest (scripts/backtest_engine.py), travada
no WINFUT 10m. O robot NÃO opera dinheiro real: apenas registra operações
simuladas (paper) em SQLite para gerar amostra viva e validar a v2.

FUNCIONAMENTO (loop intradiário):
  1. A cada NIT segundos (pregão 09:00-17:55, seg-sex), baixa os candles 5m
     mais recentes do WIN1! via TradingView (atraso ~15 min do feed anônimo).
  2. Reagrupa em 10m e roda a mesma lógica de sinais da engine v2.
  3. Sinal novo no último candle fechado → registra entrada paper a mercado.
  4. Gerencia posição aberta: alvo = M50 dinâmica, stop estrutural,
     saída no fechamento a partir de 17:30.
  5. Tudo em SQLite (data/winfut/paper_trades.sqlite) + log (bot.log) +
     alertas (data/winfut/alerts.log; Telegram se TELEGRAM_BOT_TOKEN definido).

LIMITAÇÕES HONESTAS:
  - Feed anônimo atrasado ~15 min: sinais chegam com atraso vs. corretora real.
  - O sandbox pode reiniciar; o bot registra estado no SQLite e retoma sozinho.
  - Nenhum trade real é enviado a qualquer corretora. Nunca, sem aprovação.

Uso:
  python3 scripts/winfut_bot.py --once    # uma iteração (teste)
  python3 scripts/winfut_bot.py --loop    # loop contínuo (tmux)
"""
import json
import logging
import subprocess
import sqlite3
import sys
import time
from datetime import datetime
from zoneinfo import ZoneInfo
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from backtest_engine import Backtester, Params, resample_5m_to_10m  # noqa: E402
from tv_ws_fetch import fetch  # noqa: E402
from data_collector import TZ as TZ_NAME  # noqa: E402

TZ = ZoneInfo(TZ_NAME)  # tzinfo real (data_collector exporta o nome)

DATA = (Path(__file__).resolve().parent.parent / "data" / "winfut")
DATA.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(DATA / "bot.log"), logging.StreamHandler()],
)
log = logging.getLogger("winfut_bot")

DB = DATA / "paper_trades.sqlite"
ALERTS = DATA / "alerts.log"
PREGAO_INI, PREGAO_FIM = "09:00", "17:55"
NIT = 120  # segundos entre iterações
CONF = json.loads((Path(__file__).parent / "bot_config.json").read_text()) if (
    Path(__file__).parent / "bot_config.json").exists() else {}
P = Params(**CONF.get("params", {}))  # v2: parâmetros da estratégia


# ------------------------------------------------------------------ banco
def db() -> sqlite3.Connection:
    con = sqlite3.connect(DB)
    con.execute("""CREATE TABLE IF NOT EXISTS trades (
        id INTEGER PRIMARY KEY, entry_time TEXT, entry REAL, stop REAL,
        target_ini REAL, status TEXT, exit REAL, exit_time TEXT,
        reason TEXT, pnl_pts REAL, pnl_brl REAL)""")
    con.execute("""CREATE TABLE IF NOT EXISTS sinais_vistos (
        bar_time TEXT PRIMARY KEY)""")
    con.commit()
    return con


def _migra(con):
    cols = [r[1] for r in con.execute("PRAGMA table_info(trades)")]
    if "side" not in cols:
        con.execute("ALTER TABLE trades ADD COLUMN side TEXT DEFAULT 'long'")
        con.commit()


def open_trade(con, side: str = "long") -> dict | None:
    cols = [c[1] for c in con.execute("PRAGMA table_info(trades)")]
    r = con.execute("SELECT * FROM trades WHERE status='aberto' AND side=? "
                    "ORDER BY id DESC LIMIT 1", (side,)).fetchone()
    if not r:
        return None
    return dict(zip(cols, r))


def _open_trade_side(con, side):
    return open_trade(con, side)


def alert(msg: str, title: str = "Robot WINFUT — ALERTA"):
    """Registra alerta (log + Telegram opcional) e, no Windows, abre um
    POPUP NATIVO (janela de diálogo + som do sistema) com a operação.
    O popup roda em processo separado: não bloqueia o loop do robot."""
    line = f"[{datetime.now(TZ):%Y-%m-%d %H:%M:%S}] {msg}"
    with open(ALERTS, "a") as f:
        f.write(line + "\n")
    log.info("ALERTA: %s", msg)
    tok = CONF.get("telegram_token") or ""
    chat = CONF.get("telegram_chat_id") or ""
    if tok and chat:  # só envia se o dono configurar
        try:
            import urllib.request, urllib.parse
            url = ("https://api.telegram.org/bot" + tok + "/sendMessage?"
                   + urllib.parse.urlencode({"chat_id": chat, "text": msg}))
            urllib.request.urlopen(url, timeout=10)
        except Exception as e:  # rede fora do ar não derruba o robot
            log.warning("Telegram falhou: %s", e)
    # popup nativo do Windows: janela de diálogo estilo OCO (nada em outros SOs)
    if sys.platform == "win32":
        try:
            flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            subprocess.Popen(
                [sys.executable,
                 str(Path(__file__).resolve().parent / "alert_popup.py"),
                 title, msg],
                creationflags=flags)
        except Exception as e:
            log.warning("Popup falhou: %s", e)


# ------------------------------------------------------------------ iteração
def pregao_aberto() -> bool:
    now = datetime.now(TZ)
    if now.weekday() >= 5:
        return False
    return PREGAO_INI <= now.strftime("%H:%M") <= PREGAO_FIM


def iteracao(con):
    _migra(con)
    # 1) dados frescos: 5m -> 10m
    df5 = fetch("5m", bars=1200)
    df = resample_5m_to_10m(df5)
    if len(df) < P.bias + 10:  # M200 precisa de histórico
        log.warning("Histórico insuficiente p/ M200 (%d barras)", len(df))
        return
    last = df.iloc[-1]
    last_t = df.index[-1]

    bt = Backtester(df, P)
    sig, gap = bt.signals()

    # 2) gerenciar posição aberta
    tr = open_trade(con, "long")
    if tr:
        m50_now = float(bt.m50.iloc[-1]) if not pd.isna(bt.m50.iloc[-1]) else None
        # conservador: stop antes do alvo no mesmo candle
        if float(last["low"]) <= tr["stop"]:
            fechar(con, tr, tr["stop"], "stop", last_t)
            return
        alvo = (m50_now + P.tgt_offset_pts) if m50_now else None
        if alvo and float(last["high"]) >= alvo:
            fechar(con, tr, alvo, "alvo", last_t)
            return
        now = datetime.now(TZ)
        if now.strftime("%H:%M") >= P.eod_time:
            fechar(con, tr, float(last["close"]), "eod", last_t)
            return
        log.info("Posição aberta desde %s | preço %.0f | stop %.0f | alvo M50 %.0f",
                 tr["entry_time"], float(last["close"]), tr["stop"],
                 m50_now if m50_now else -1)
        return

    # 3) gestão do SHORT da pernada (v4), se aberto
    if P.enable_pernada_short:
        sh = _open_trade_side(con, "short")
        if sh:
            m50_now = float(bt.m50.iloc[-1]) if not pd.isna(bt.m50.iloc[-1]) else None
            if float(last["high"]) >= sh["stop"]:
                fechar(con, sh, sh["stop"], "stop_pernada", last_t)
            elif m50_now and float(last["low"]) <= m50_now:
                fechar(con, sh, m50_now, "alvo_pernada", last_t)
            elif datetime.now(TZ).strftime("%H:%M") >= P.eod_time:
                fechar(con, sh, float(last["close"]), "eod_short", last_t)
            else:
                log.info("SHORT aberto desde %s | preço %.0f | stop %.0f | alvo M50 %.0f",
                         sh["entry_time"], float(last["close"]), sh["stop"],
                         m50_now if m50_now else -1)

    # 4) sinal pernada novo no último candle fechado?
    if P.enable_pernada_short and not sh:
        m9v = float(bt.m9.iloc[-1]); m50v = float(bt.m50.iloc[-1]); m200v = float(bt.m200.iloc[-1])
        prev_ok = False
        if len(df) > 1:
            m50p = float(bt.m50.iloc[-2])
            prev_ok = (m9v < m50v < m200v) and (float(df["close"].iloc[-2]) - m50p < P.pernada_th_pts)
        if ((m9v < m50v < m200v) and (float(last["close"]) - m50v) >= P.pernada_th_pts
                and prev_ok):
            key = "S:" + str(last_t)
            if not con.execute("SELECT 1 FROM sinais_vistos WHERE bar_time=?", (key,)).fetchone():
                con.execute("INSERT OR IGNORE INTO sinais_vistos VALUES (?)", (key,))
                con.commit()
                entry_s = float(last["close"]) - P.slippage_pts       # vende
                stop_s = float(last["high"]) + P.pernada_stop_atr * float(
                    bt.atr14.iloc[-1] if not pd.isna(bt.atr14.iloc[-1]) else 0.0)
                con.execute(
                    "INSERT INTO trades (entry_time, entry, stop, target_ini, status, side) "
                    "VALUES (?,?,?,?,'aberto','short')", (str(last_t), entry_s, stop_s, m50v))
                con.commit()
                alert(
                    f"AÇÃO: VENDA WINFUT @ {entry_s:.0f}  (pernada/exaustão)\n\n"
                    f"OCO — COMPRAS de proteção (colocar no Profit):\n"
                    f"   • COMPRA stop-loss @ {stop_s:.0f}\n"
                    f"   • COMPRA alvo @ {m50v:.0f}  (retorno à M50)\n\n"
                    f"Extensão acima da M50: {float(last['close']) - m50v:.0f} pts "
                    f"| candle {last_t}",
                    title="🔻 SINAL VENDA — Robot WINFUT (paper)")

    # 5) sinal COMPRA novo no último candle fechado? (índice -1 já é candle fechado
    #    porque o fetch descarta a barra em formação)
    if not bool(sig.iloc[-1]):
        log.info("Sem sinal | %s close=%.0f", last_t, float(last["close"]))
        return
    key = str(last_t)
    if con.execute("SELECT 1 FROM sinais_vistos WHERE bar_time=?", (key,)).fetchone():
        return  # já processado
    con.execute("INSERT OR IGNORE INTO sinais_vistos VALUES (?)", (key))

    # 4) entrada paper a mercado (preço do último fechamento + slippage)
    entry = float(last["close"]) + P.slippage_pts
    swing = float(df["low"].rolling(P.swing_lookback, min_periods=2).min().iloc[-1])
    atr = float(bt.atr14.iloc[-1]) if not pd.isna(bt.atr14.iloc[-1]) else 0.0
    stop = swing - P.stop_atr_mult * atr
    if entry <= stop:
        log.info("Sinal descartado: entry<=stop")
        return
    m50 = float(bt.m50.iloc[-1])
    con.execute(
        "INSERT INTO trades (entry_time, entry, stop, target_ini, status) "
        "VALUES (?,?,?,?,'aberto')", (str(last_t), entry, stop, m50))
    con.commit()
    alvo = m50 + P.tgt_offset_pts
    alert(
        f"AÇÃO: COMPRA WINFUT @ {entry:.0f}\n\n"
        f"OCO — VENDAS de proteção (colocar no Profit):\n"
        f"   • VENDA stop-loss @ {stop:.0f}\n"
        f"   • VENDA alvo @ {alvo:.0f}  (M50 {m50:.0f} + {P.tgt_offset_pts:.0f})\n\n"
        f"Prêmio até o alvo: {alvo - entry:.0f} pts | candle {last_t}",
        title="📈 SINAL COMPRA — Robot WINFUT (paper)")


def fechar(con, tr, exit_px, reason, t):
    side = tr.get("side") or "long"
    # PnL com sinal correto: long = exit-entry; short = entry-exit
    pnl_pts = (exit_px - tr["entry"] if side == "long"
               else tr["entry"] - exit_px) - P.slippage_pts
    fin_vol = (tr["entry"] + exit_px) * P.ponto
    custos = 2 * P.corretagem + fin_vol * P.emol_pct
    pnl_brl = pnl_pts * P.ponto - custos
    con.execute("UPDATE trades SET status='fechado', exit=?, exit_time=?, "
                "reason=?, pnl_pts=?, pnl_brl=? WHERE id=?",
                (exit_px, str(t), reason, pnl_pts, pnl_brl, tr["id"]))
    con.commit()
    titulos = {
        "alvo": "🎯 ALVO ATINGIDO", "alvo_pernada": "🎯 ALVO ATINGIDO (pernada)",
        "stop": "🛑 STOP ATINGIDO", "stop_pernada": "🛑 STOP ATINGIDO (pernada)",
        "eod": "🌙 ENCERRAMENTO DO DIA (EOD)", "eod_short": "🌙 ENCERRAMENTO (EOD short)",
    }
    alert(f"Saída @ {exit_px:.0f} | motivo {reason.upper()}\n\n"
          f"RESULTADO: {pnl_pts:+.0f} pts  (R$ {pnl_brl:+.2f})\n"
          f"Lado: {'VENDA' if side == 'short' else 'COMPRA'} | saída {t}",
          title=titulos.get(reason, "FECHAMENTO") + " — Robot WINFUT (paper)")


def main():
    if "--once" in sys.argv:
        con = db()
        if not pregao_aberto():
            log.info("Fora do pregão; executando iteração de teste mesmo assim.")
        iteracao(con)
        return
    log.info("=== Robot paper WINFUT v2 iniciado (loop %ds) ===", NIT)
    con = db()
    while True:
        try:
            if pregao_aberto():
                iteracao(con)
            else:
                # fora do pregão: e se houver posição aberta de ontem? (não deve
                # acontecer no day trade, mas por segurança registra)
                pass
        except Exception:
            log.exception("Erro na iteração (robot continua)")
        time.sleep(NIT)


if __name__ == "__main__":
    main()
