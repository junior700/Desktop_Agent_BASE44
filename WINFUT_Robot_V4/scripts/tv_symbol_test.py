import json, random, re, string, time, threading
import websocket

def rnd(): return "".join(random.choices(string.ascii_letters+string.digits, k=12))

def test_symbol(sym):
    chart = "cs_" + rnd()
    result = {"sym": sym, "ok": False}
    def send(ws, d):
        s = json.dumps(d)
        ws.send("~m~" + str(len(s)) + "~m~" + s)
    def on_open(ws):
        send(ws, {"m": "set_auth_token", "p": ["unauthorized_user_token"]})
        send(ws, {"m": "chart_create_session", "p": [chart, ""]})
        send(ws, {"m": "resolve_symbol", "p": [chart, "sds_sym_1",
            '={"symbol":"' + sym + '","adjustment":"splits","session":"regular"}']})
    def on_message(ws, raw):
        for m in re.findall(r"~m~\d+~m~(.+?)(?=~m~\d+~m~|$)", raw, re.S):
            if "symbol_error" in m:
                result["err"] = m[:120]; ws.close()
            elif '"m":"series_completed"' in m or '"m":"symbol resolved"' in m or "'m': 'symbol" in m:
                pass
            if '"nm"' in m or "resolved" in m or '"ty"' in m:
                result.setdefault("msgs", []).append(m[:150])
    def on_error(ws, e): pass
    ws = websocket.WebSocketApp(
        "wss://data.tradingview.com/socket.io/websocket?EIO=3&transport=websocket",
        on_open=on_open, on_message=on_message)
    threading.Thread(target=lambda: ws.run_forever(), daemon=True).start()
    time.sleep(3)
    # resposta positiva vem como resolve_symbol com body; vamos ver
    return result

for s in ["BMFEX:WIN1!", "BMFBOVESPA:WIN1!", "WIN1!", "BMFEX:WINZ2027",
          "BMFEX:IND1!", "BMFEX:WIN2!", "BMFEX:WDO1!"]:
    r = test_symbol(s)
    print(f"{s:22s} -> err={r.get('err','?')[:90]} msgs={len(r.get('msgs',[]))}")
