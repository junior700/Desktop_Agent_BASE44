import requests
H = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"}
url = "https://br.advfn.com/mercado/bmfbovespa/WINFUT/cotacao"
r = requests.get(url, headers=H, timeout=15)
print("status:", r.status_code, "len:", len(r.text))
import re
m = re.search(r'Última Negocia|Último|Cotação', r.text)
print("tem cotação:", bool(m))
# histórico
for u in ["https://br.advfn.com/bmfbovespa/WINFUT-historico",
          "https://br.advfn.com/mercado/bmfbovespa/WINFUT/historico"]:
    r2 = requests.get(u, headers=H, timeout=15)
    print(u, "->", r2.status_code, len(r2.text))
