from tvDatafeed import TvDatafeed, Interval
t = TvDatafeed()  # sem login
for sym, exch in [("WIN1!", "BMFEX"), ("WIN2!", "BMFEX"), ("IBOV", "BMFBOVESPA")]:
    try:
        df = t.get_hist(sym, exch, interval=Interval.in_daily, n_bars=5000)
        if df is not None and len(df) > 0:
            print(f"OK {exch}:{sym} -> {len(df)} barras | {df.index[0].date()} a {df.index[-1].date()}")
            print(df.tail(3))
        else:
            print(f"-- {exch}:{sym}: sem dados")
    except Exception as e:
        print(f"ERRO {exch}:{sym}: {type(e).__name__}: {e}")
