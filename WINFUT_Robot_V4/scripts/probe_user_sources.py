import yfinance as yf
print("=== Yahoo: ticker WIN=FUT ===")
try:
    h = yf.Ticker("WIN=FUT").history(start="2024-01-01", interval="1d")
    print("barras:", len(h))
    if len(h): print(h.tail(2))
except Exception as e:
    print("ERRO:", type(e).__name__, e)
print("\n=== Yahoo: tickers alternativos futuros ===")
for t in ["WINFUT.SA", "WINZ26.SA", "WIN=F"]:
    try:
        h = yf.download(t, period="1mo", progress=False)
        print(f"{t}: {len(h)} barras" if len(h) else f"{t}: sem dados")
    except Exception as e:
        print(f"{t}: ERRO {e}")
