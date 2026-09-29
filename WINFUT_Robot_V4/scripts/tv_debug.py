"""Loga mensagens cruas do websocket TradingView p/ debug do protocolo."""
import json, random, re, string
import websocket

def rnd(): return "".join(random.choices(string.ascii_letters+string.digits, k=12))
session = "qs_" + rnd()
chart = "cs_" + rnd()
sym = "BMFEX:WIN1!"

def send(ws, d):
    s = json.dumps(d)
    ws.send("~m~" + str(len(s)) + "~m~" + s)

def on_open(ws):
    print("OPEN")
    send(ws, {"m": "set_auth_token", "p": ["unauthorized_user_token"]})
    send(ws, {"m": "chart_create_session", "p": [chart, ""]})
    send(ws, {"m": "resolve_symbol", "p": [chart, "sds_sym_1",
        '={"symbol":"' + sym + '","adjustment":"splits","session":"regular"}']})
    send(ws, {"m": "create_series", "p": [chart, "sds_1", "s1", "sds_sym_1", "1D", 300, ""]})

def on_message(ws, raw):
    for m in re.findall(r"~m~(\d+)~m~(.+?)(?=~m~\d+~m~|$)", raw, re.S):
        payload = m[1]
        if payload.startswith("~h~"):
            ws.send(raw)  # echo heartbeat
            continue
        print("MSG:", payload[:600].replace("\n", " "))

def on_error(ws, e): print("ERR:", e)

ws = websocket.WebSocketApp(
    "wss://data.tradingview.com/socket.io/websocket?EIO=3&transport=websocket",
    on_open=on_open, on_message=on_message, on_error=on_error)
import threading
threading.Thread(target=lambda: ws.run_forever(), daemon=True).start()
import time; time.sleep(25)
try: ws.close()
except: pass
