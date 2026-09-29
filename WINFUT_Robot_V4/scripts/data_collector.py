"""
data_collector.py — Coleta e organização de dados do WINFUT (mini índice B3)
=============================================================================
Fontes suportadas:
  1. Brapi (WINFUT real) ............... exige token gratuito em brapi.dev
  2. Yahoo Finance (^BVSP como proxy) ... funciona sem token
  3. Importação CSV (Profit / Tryd / MetaTrader 5)

Arquitetura: cada fonte vira um DataFrame padronizado com colunas
  [datetime, open, high, low, close, volume]  (datetime tz America/Sao_Paulo)

Saída: CSV + Parquet em /data/winfut/{daily,intraday}/ e catálogo em SQLite
  (winfut.sqlite: tabela 'catalogo' com metadados de cada série baixada).

Uso:
  python3 scripts/data_collector.py yahoo-daily            # baixa/atualiza diário (proxy BVSP)
  python3 scripts/data_collector.py yahoo-intraday 15m      # intradiário (janela limitada)
  python3 scripts/data_collector.py brapi-daily              # WINFUT real (requer BRAPI_TOKEN)
  python3 scripts/data_collector.py import-csv caminho.csv daily [--sep ; --dec ,]
  python3 scripts/data_collector.py validate daily           # valida qualidade da base
  python3 scripts/data_collector.py update-all               # atualização automática (agendável)

Limitações conhecidas (honestidade primeiro):
  - Yahoo não lista o WINFUT; usamos ^BVSP (Ibovespa à vista). O WINFUT replica
    o Ibov quase 1:1 no intraday (base pequena), então serve para validar a
    LÓGICA de estratégias, mas P&L em pontos de WIN (R$ 0,20/pt) e custos reais
    só entram com dados reais do contrato.
  - Yahoo intradiário: 5m/15m com janela de ~60 dias; 1h ~730 dias.
  - Brapi: plano gratuito tem limites de requisições; histórico de WINFUT
    depende da disponibilidade no momento da chamada.
"""
import argparse
import logging
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import requests

# ------------------------------------------------------------------ constantes
TZ = "America/Sao_Paulo"
BASE = Path(__file__).resolve().parent.parent / "data" / "winfut"
DAILY_DIR = BASE / "daily"
INTRADAY_DIR = BASE / "intraday"
SQLITE_PATH = BASE / "winfut.sqlite"
PREGAO_INICIO = pd.Timestamp("10:00").time()   # pregão B3 (horário padrão)
PREGAO_FIM = pd.Timestamp("17:30").time()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("data_collector")


def _ensure_dirs():
    DAILY_DIR.mkdir(parents=True, exist_ok=True)
    INTRADAY_DIR.mkdir(parents=True, exist_ok=True)


# ------------------------------------------------------------------ normalização
def normalize_ohlcv(df: pd.DataFrame, freq: str) -> pd.DataFrame:
    """Padroniza colunas, índice datetime (fuso SP), tipos e remove lixo."""
    df = df.copy()
    df.columns = [str(c).lower().replace("<", "").replace(">", "") for c in df.columns]
    ren = {"abertura": "open", "abertur": "open", "abert": "open",
           "maximo": "high", "maxim": "high", "max": "high",
           "minimo": "low", "minim": "low", "min": "low",
           "ultimo": "close", "ultim": "close", "fechamento": "close",
           "volume_total": "volume", "voltot": "volume", "vol": "volume"}
    df = df.rename(columns=ren)
    # fallback por prefixo: aber->open, maxi->high, mini->low, (u|fech)->close, vol->volume
    pref = {"aber": "open", "maxi": "high", "mini": "low", "vol": "volume"}
    for c in list(df.columns):
        cl = str(c).lower()
        if cl.startswith("ult") or cl.startswith("fech"):
            df = df.rename(columns={c: "close"})
        else:
            for p, alvo in pref.items():
                if cl.startswith(p):
                    df = df.rename(columns={c: alvo})
    need = {"open", "high", "low", "close"}
    missing = need - set(df.columns)
    if missing:
        raise ValueError(f"Colunas ausentes: {missing}. Encontradas: {list(df.columns)}")

    df = df.reset_index()
    df.columns = [str(c).lower() for c in df.columns]
    dtcol = next((c for c in df.columns if c in ("datetime", "date", "data", "horario", "time", "index")), None)
    if dtcol is None:
        raise ValueError(f"Nenhuma coluna de data encontrada. Colunas: {list(df.columns)}")
    df = df.rename(columns={dtcol: "datetime"})

    dayfirst = False
    if df["datetime"].dtype == object:
        amostra = df["datetime"].dropna().astype(str).head(50)
        dayfirst = bool(amostra.str.match(r"\d{1,2}/\d{1,2}/\d{2,4}").mean() > 0.8)
    df["datetime"] = pd.to_datetime(df["datetime"], errors="coerce", utc=True, dayfirst=dayfirst)
    df = df.dropna(subset=["datetime"])
    if freq == "daily":
        # datas diárias: sem hora/fuso (evita erros de DST em meia-noite)
        df["datetime"] = df["datetime"].dt.tz_convert("UTC").dt.normalize().dt.tz_localize(None)
    else:
        df["datetime"] = df["datetime"].dt.tz_convert(TZ)

    for c in ("open", "high", "low", "close"):
        df[c] = pd.to_numeric(df[c], errors="coerce")
    if "volume" in df.columns:
        df["volume"] = pd.to_numeric(df["volume"], errors="coerce").fillna(0).astype("int64")
    else:
        df["volume"] = 0

    df = df.dropna(subset=["open", "high", "low", "close"])
    df = df[["datetime", "open", "high", "low", "close", "volume"]]
    df = df.drop_duplicates(subset="datetime").sort_values("datetime").set_index("datetime")
    return df


# ------------------------------------------------------------------ fontes
def fetch_yahoo(symbol: str, interval: str, period: str = "max") -> pd.DataFrame:
    import yfinance as yf
    raw = yf.download(symbol, period=period, interval=interval,
                      progress=False, auto_adjust=False)
    if raw is None or raw.empty:
        raise RuntimeError(f"Yahoo sem dados para {symbol} {interval}")
    if isinstance(raw.columns, pd.MultiIndex):        # colunas multi-nível (yfinance novo)
        raw.columns = raw.columns.get_level_values(0)
    return normalize_ohlcv(raw, "daily" if interval == "1d" else "intraday")


def fetch_brapi_winfut(token: str) -> pd.DataFrame:
    """WINFUT real via Brapi (SDK oficial 'pip install brapi'; fallback HTTP)."""
    hist = None
    # 1) SDK oficial brapi (pip install brapi)
    try:
        from brapi import Brapi
        client = Brapi(api_key=token)
        res = client.quote.retrieve("WINFUT")
        hist = res.get("historicalData") if isinstance(res, dict) else getattr(res, "historicalData", None)
    except Exception as e:
        log.warning("SDK brapi falhou (%s); tentando HTTP direto", type(e).__name__)
    # 2) fallback HTTP
    if not hist:
        r = requests.get("https://brapi.dev/api/quote/WINFUT",
                         params={"token": token, "range": "1y", "interval": "1d"},
                         timeout=30)
        r.raise_for_status()
        js = r.json()
        results = js.get("results") or []
        hist = results[0].get("historicalData") if results else None
    if not hist:
        raise RuntimeError("Brapi não devolveu historicalData para WINFUT "
                           "(verifique plano/limite do token)")
    return normalize_ohlcv(pd.DataFrame(hist), "daily")


def import_csv(path: str, freq: str, sep: str = ";", dec: str = ".") -> pd.DataFrame:
    """Importa CSV exportado de Profit/Tryd/MT5. Detecta colunas BR e EN."""
    df = pd.read_csv(path, sep=sep, decimal=dec)
    return normalize_ohlcv(df, freq)


# ------------------------------------------------------------------ persistência
def save_ohlcv(df: pd.DataFrame, name: str, freq: str, source: str) -> Path:
    """Salva CSV + Parquet e registra no catálogo SQLite (merge incremental)."""
    _ensure_dirs()
    d = DAILY_DIR if freq == "daily" else INTRADAY_DIR
    csv_path = d / f"{name}.csv"
    parq_path = d / f"{name}.parquet"

    if csv_path.exists():                            # merge com base existente
        old = pd.read_csv(csv_path, index_col=0, parse_dates=True)
        if freq != "daily":
            old.index = old.index.tz_localize(TZ) if old.index.tz is None else old.index.tz_convert(TZ)
        df = pd.concat([old, df[~df.index.isin(old.index)]])
        df = df[~df.index.duplicated(keep="last")].sort_index()

    df.to_csv(csv_path)
    df.to_parquet(parq_path)

    with sqlite3.connect(SQLITE_PATH) as con:
        con.execute("""CREATE TABLE IF NOT EXISTS catalogo (
            nome TEXT, freq TEXT, fonte TEXT, barras INTEGER,
            inicio TEXT, fim TEXT, atualizado_em TEXT)""")
        con.execute("DELETE FROM catalogo WHERE nome=? AND freq=?", (name, freq))
        con.execute("INSERT INTO catalogo VALUES (?,?,?,?,?,?,?)",
                    (name, freq, source, len(df),
                     str(df.index[0]), str(df.index[-1]),
                     datetime.now(timezone.utc).isoformat()))
    log.info("Salvo %s: %d barras (%s a %s)", name, len(df),
             df.index[0].date(), df.index[-1].date())
    return csv_path


# ------------------------------------------------------------------ validação
def validate(name: str, freq: str) -> dict:
    """Checa gaps, inconsistências OHLC e horário de pregão."""
    d = DAILY_DIR if freq == "daily" else INTRADAY_DIR
    path = d / f"{name}.parquet"
    if not path.exists():
        raise FileNotFoundError(path)
    df = pd.read_parquet(path)
    rep = {"serie": name, "freq": freq, "barras": len(df),
           "inicio": str(df.index[0]), "fim": str(df.index[-1])}

    # inconsistências OHLC
    bad = ((df["high"] < df[["open", "low", "close"]].max(axis=1)) |
           (df["low"] > df[["open", "high", "close"]].min(axis=1)))
    rep["barras_ohlc_inconsistentes"] = int(bad.sum())

    # valores zerados/nulos
    rep["barras_zeradas"] = int((df["close"] <= 0).sum())

    if freq == "daily":
        # gaps de dias úteis (desconta feriados aprox. via regra: gap > 4 dias úteis seguidos)
        dias = df.index.to_series().dt.date
        diffs = df.index.to_series().diff().dt.days
        gaps = dias[(diffs > 4)]
        rep["gaps_grandes_dias"] = int(len(gaps))
        if len(gaps):
            rep["gaps_exemplos"] = [str(g) for g in gaps.head(5)]
    else:
        # barras fora do pregão-padrão (B3: 09h00-18h25 nos últimos anos)
        horas = pd.Series(df.index.time, index=df.index)
        fora = (horas < pd.Timestamp("09:00").time()) | (horas > pd.Timestamp("18:25").time())
        rep["barras_fora_pregao_padrao"] = int(fora.sum())
        gaps_min = df.index.to_series().diff().dt.total_seconds() / 60
        rep["gap_maximo_min"] = float(gaps_min.max())

    # fuso
    rep["fuso"] = str(df.index.tz) or "naive (diário)"
    rep["status"] = "OK" if (rep["barras_ohlc_inconsistentes"] == 0 and
                             rep["barras_zeradas"] == 0) else "REVISAR"
    return rep


# ------------------------------------------------------------------ CLI
def main():
    p = argparse.ArgumentParser(description="Coletor de dados WINFUT")
    p.add_argument("cmd", choices=["yahoo-daily", "yahoo-intraday", "brapi-daily",
                                   "import-csv", "validate", "catalog", "update-all"])
    p.add_argument("arg", nargs="?", default=None)
    p.add_argument("freq", nargs="?", default="daily")
    p.add_argument("--sep", default=";")
    p.add_argument("--dec", default=".")
    args = p.parse_args()
    _ensure_dirs()

    if args.cmd == "yahoo-daily":
        df = fetch_yahoo("^BVSP", "1d", period="max")
        save_ohlcv(df, "ibov_daily_proxy", "daily", "yahoo:^BVSP (proxy do WINFUT)")
        df = fetch_yahoo("^BVSP", "1h", period="730d")
        save_ohlcv(df, "ibov_1h_proxy", "intraday", "yahoo:^BVSP (proxy do WINFUT)")

    elif args.cmd == "yahoo-intraday":
        iv = args.arg or "5m"
        period = {"1m": "7d", "5m": "60d", "15m": "60d", "30m": "60d"}.get(iv)
        if not period:
            raise SystemExit("Intervalo inválido (use 1m/5m/15m/30m)")
        df = fetch_yahoo("^BVSP", iv, period=period)
        save_ohlcv(df, f"ibov_{iv}_proxy", "intraday", "yahoo:^BVSP (proxy)")

    elif args.cmd == "brapi-daily":
        token = os.environ.get("BRAPI_TOKEN") or input("Cole seu token Brapi: ")
        df = fetch_brapi_winfut(token)
        save_ohlcv(df, "winfut_daily", "daily", "brapi:WINFUT")

    elif args.cmd == "import-csv":
        if not args.arg:
            raise SystemExit("Informe o caminho do CSV")
        df = import_csv(args.arg, args.freq, args.sep, args.dec)
        nome = Path(args.arg).stem
        save_ohlcv(df, nome, args.freq, f"import:{nome}")

    elif args.cmd == "validate":
        nome = args.arg or "ibov_daily_proxy"
        print(pd.Series(validate(nome, args.freq)).to_string())

    elif args.cmd == "catalog":
        with sqlite3.connect(SQLITE_PATH) as con:
            for row in con.execute("SELECT * FROM catalogo ORDER BY nome"):
                print(row)

    elif args.cmd == "update-all":
        df = fetch_yahoo("^BVSP", "1d", period="max")
        save_ohlcv(df, "ibov_daily_proxy", "daily", "yahoo:^BVSP (proxy do WINFUT)")
        df = fetch_yahoo("^BVSP", "1h", period="730d")
        save_ohlcv(df, "ibov_1h_proxy", "intraday", "yahoo:^BVSP (proxy do WINFUT)")
        if os.environ.get("BRAPI_TOKEN"):
            try:
                df = fetch_brapi_winfut(os.environ["BRAPI_TOKEN"])
                save_ohlcv(df, "winfut_daily", "daily", "brapi:WINFUT")
            except Exception as e:
                log.warning("Brapi falhou: %s", e)
        for nome, freq in [("ibov_daily_proxy", "daily"), ("ibov_1h_proxy", "intraday")]:
            print(pd.Series(validate(nome, freq)).to_string())


if __name__ == "__main__":
    main()
