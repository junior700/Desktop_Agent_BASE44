"""
tv_ws_fetch.py — Histórico real do WINFUT via protocolo público do TradingView
================================================================================
Símbolo: BMFBOVESPA:WIN1! (contrato contínuo do mini índice, B3)
Protocolo: socket.io v2 do TradingView (websocket, sem login — usuário anônimo).
Integra com data_collector.py (normalização, CSV/Parquet, catálogo SQLite).

Limitações:
  - API não oficial: pode mudar sem aviso.
  - Cotação atrasada ~15 min no acesso anônimo ("delayed_streaming_900").
  - Intraday anônimo: até ~5.000 barras por chamada (15m ≈ 2 anos, 5m ≈ 8 meses).
  - WIN1! é o contínuo: rolagens de vencimento embutidas na série da TV.

Uso:
  python3 scripts/tv_ws_fetch.py daily            # diário, 5000 barras (~20 anos)
  python3 scripts/tv_ws_fetch.py 15               # 15 minutos, 5000 barras
  python3 scripts/tv_ws_fetch.py 5                # 5 minutos, 5000 barras
"""
import json
import logging
import random
import re
import string
import sys
import threading
import time
from datetime import datetime, timezone

import pandas as pd
import websocket

sys.path.insert(0, str(__file__.rsplit("/", 1)[0]))
from data_collector import save_ohlcv, TZ, log  # noqa: E402

from pathlib import Path
DATA_ROOT = Path(__file__).resolve().parent.parent / "data"

WS_URL = "wss://data.tradingview.com/socket.io/websocket?EIO=3&transport=websocket"
SYMBOL = "BMFBOVESPA:WIN1!"
# ativos suportados: win (mini indice) | wdo (mini dolar)
ASSETS = {
    "win": {"symbol": "BMFBOVESPA:WIN1!", "name": "winfut"},
    "wdo": {"symbol": "BMFBOVESPA:WDO1!", "name": "wdofut"},
}
IV = {"1m": "1", "5m": "5", "10m": "10", "15m": "15", "30m": "30", "60": "60",
      "1D": "1D", "1W": "1W", "1M": "1M"}


def _rand():
    return "".join(random.choices(string.ascii_letters + string.digits, k=12))


class TVHistory:
    def __init__(self, interval: str, bars: int, symbol: str = SYMBOL):
        self.symbol = symbol
        self.interval = IV[interval]
        self.bars = bars
        self.chart = "cs_" + _rand()
        self.candles = {}
        self.completed = False

    def _send(self, ws, msg: dict):
        s = json.dumps(msg)
        ws.send("~m~" + str(len(s)) + "~m~" + s)

    def _ingest(self, datapoints):
        for dp in datapoints:
            v = dp.get("v")
            if not v or len(v) < 6:
                continue
            ts, o, h, l, c, vol = v[0], v[1], v[2], v[3], v[4], v[5]
            ts = float(ts)
            if self.interval == "1D":
                dt = pd.Timestamp(ts, unit="s", tz="UTC").tz_localize(None).normalize()
            else:
                dt = pd.Timestamp(ts, unit="s", tz="UTC").tz_convert(TZ)
            self.candles[float(ts)] = {"datetime": dt, "open": o, "high": h,
                                       "low": l, "close": c, "volume": vol or 0}

    def on_open(self, ws):
        self._send(ws, {"m": "set_auth_token", "p": ["unauthorized_user_token"]})
        self._send(ws, {"m": "chart_create_session", "p": [self.chart, ""]})
        self._send(ws, {"m": "resolve_symbol", "p": [
            self.chart, "sds_sym_1",
            '={"symbol":"' + self.symbol + '","adjustment":"splits","session":"regular"}']})
        self._send(ws, {"m": "create_series", "p": [
            self.chart, "sds_1", "s1", "sds_sym_1", self.interval, self.bars, ""]})

    def on_message(self, ws, raw: str):
        # heartbeat: responder eco imediatamente
        if raw.startswith("~m~") and "~h~" in raw:
            ws.send(raw)
            return
        for m in re.findall(r"~m~\d+~m~(.+?)(?=~m~\d+~m~|$)", raw, re.S):
            m = m.strip()
            if not m.startswith("{"):
                continue
            try:
                msg = json.loads(m)
            except json.JSONDecodeError:
                continue
            method = msg.get("m")
            if method == "timescale_update":
                payload = msg["p"][1]
                series = payload.get("sds_1") or {}
                self._ingest(series.get("s") or [])
            elif method == "du":
                payload = msg["p"][1]
                series = payload.get("sds_1") or {}
                self._ingest(series.get("s") or [])
            elif method == "series_completed":
                self.completed = True
            elif method == "series_error":
                raise RuntimeError(f"Series error: {msg['p']}")

    def run(self, timeout_s: int = 90) -> pd.DataFrame:
        ws = websocket.WebSocketApp(
            WS_URL, on_open=self.on_open, on_message=self.on_message,
            on_error=lambda w, e: log.error("WS: %s", e))
        threading.Thread(target=lambda: ws.run_forever(ping_interval=20), daemon=True).start()
        t0 = time.time()
        while time.time() - t0 < timeout_s and not self.completed:
            time.sleep(0.3)
        # espera extra: série completa pode chegar em blocos
        if self.completed:
            t0 = time.time()
            while time.time() - t0 < 3:
                time.sleep(0.5)
        try:
            ws.close()
        except Exception:
            pass
        if not self.candles:
            raise RuntimeError("Sem candles (símbolo inválido ou protocolo alterado)")
        df = pd.DataFrame(list(self.candles.values()))
        df = df.sort_values("datetime").drop_duplicates(subset="datetime").set_index("datetime")
        # remove última barra em formação (não fechada)
        df = df.iloc[:-1]
        log.info("Recebidas %d barras de %s:%s", len(df), self.symbol, self.interval)
        return df[["open", "high", "low", "close", "volume"]]


def fetch(interval: str, bars: int = 5000, symbol: str = SYMBOL) -> pd.DataFrame:
    return TVHistory(interval, bars, symbol).run()


def main():
    iv = sys.argv[1] if len(sys.argv) > 1 else "1D"
    asset = sys.argv[2] if len(sys.argv) > 2 else "win"
    if iv not in IV:
        raise SystemExit(f"Intervalos válidos: {list(IV.keys())}")
    if asset not in ASSETS:
        raise SystemExit(f"Ativos válidos: {list(ASSETS)}")
    cfg = ASSETS[asset]
    df = fetch(iv, symbol=cfg["symbol"])
    freq = "daily" if iv in ("1D", "1W", "1M") else "intraday"
    base = cfg["name"]
    name = {"1D": f"{base}_daily", "15": f"{base}_15m", "5": f"{base}_5m",
            "1": f"{base}_1m", "10": f"{base}_10m", "30": f"{base}_30m", "60": f"{base}_1h",
            "1W": f"{base}_1w", "1M": f"{base}_1mM"}.get(iv, f"{base}_{iv}")
    if asset != "win":
        # redireciona pastas/catálogo p/ o ativo (data/<base>/...)
        import data_collector as dc
        root = DATA_ROOT / base
        (root / "daily").mkdir(parents=True, exist_ok=True)
        (root / "intraday").mkdir(parents=True, exist_ok=True)
        dc.DAILY_DIR = root / "daily"
        dc.INTRADAY_DIR = root / "intraday"
        dc.SQLITE_PATH = root / f"{base}.sqlite"
    save_ohlcv(df, name, freq, f"tradingview:{cfg['symbol']}")


if __name__ == "__main__":
    main()
