import yfinance as yf
df = yf.download("^BVSP", start="1995-01-01", interval="1d", progress=False, auto_adjust=False)
print("Barras:", len(df))
print("Período:", df.index[0].date(), "a", df.index[-1].date())
print(df.tail(2))
# intraday
for iv, per in [("5m","60d"), ("15m","60d"), ("1h","730d")]:
    d2 = yf.download("^BVSP", period=per, interval=iv, progress=False)
    print(f"intraday {iv}: {len(d2)} barras | {d2.index[0]} a {d2.index[-1]}" if len(d2) else f"intraday {iv}: vazio")
