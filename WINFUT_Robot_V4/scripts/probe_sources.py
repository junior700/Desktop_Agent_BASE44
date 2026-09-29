"""Sonda de fontes de dados para WINFUT - testa quais funcionam e o período disponível."""
import yfinance as yf
import requests

print("=== 1. Yahoo Finance: tickers candidatos ===")
candidates = ["WIN=F", "WINFUT", "INDFUT", "^BVSP", "WINSF.F", "WIN=F.SA"]
for t in candidates:
    try:
        h = yf.download(t, period="1mo", interval="1d", progress=False, auto_adjust=False)
        if h is not None and len(h) > 0:
            print(f"  OK  {t}: {len(h)} barras, ultima: {h.index[-1].date()}, close={float(h['Close'].iloc[-1].iloc[0] if isinstance(h['Close'], pd.DataFrame) else h['Close'].iloc[-1]):.0f}")
        else:
            print(f"  --  {t}: sem dados")
    except Exception as e:
        print(f"  ERRO {t}: {type(e).__name__}: {e}")

print("\n=== 2. Brapi (API BR gratuita) ===")
try:
    r = requests.get("https://brapi.dev/api/quote/WINFUT", timeout=15)
    print("  status:", r.status_code, "->", r.text[:300])
except Exception as e:
    print("  ERRO:", e)

print("\n=== 3. Brapi sem token - lista de tickers de futuros ===")
try:
    r = requests.get("https://brapi.dev/api/quote/WIN%24F,IND%24F,WDO%24F", timeout=15)
    print("  status:", r.status_code, "->", r.text[:500])
except Exception as e:
    print("  ERRO:", e)
