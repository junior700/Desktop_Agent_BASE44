# Base de Dados WINFUT — Documentação (Fase 1)

Atualizado em: 2026-09-28

## Estrutura

```
data/winfut/
├── daily/          # candles diários (CSV + Parquet)
├── intraday/       # candles intradiários (CSV + Parquet)
└── winfut.sqlite   # catálogo das séries (tabela 'catalogo')
scripts/
├── data_collector.py       # módulo de coleta (fontes, normalização, validação)
└── probe_*.py              # sondas de teste das fontes (referência)
```

Colunas padronizadas: `datetime, open, high, low, close, volume`.
Diário: datas sem hora (naive). Intraday: tz `America/Sao_Paulo`.

## Série disponíveis (baixadas e validadas)

| Série | Freq | Período | Barras | Fonte |
|---|---|---|---|---|
| **winfut_daily** | **1D** | **2006-07-18 a 2026-09-25** | **4.999** | **TradingView WIN1! (REAL)** |
| **winfut_15m** | **15m** | **2026-03-19 a 2026-09-28** | **4.999** | **TradingView WIN1! (REAL)** |
| **winfut_5m** | **5m** | **2026-07-27 a 2026-09-28** | **4.999** | **TradingView WIN1! (REAL)** |
| ibov_daily_proxy | 1D | 1993-04-27 a 2026-09-28 | 8.279 | Yahoo ^BVSP |
| ibov_1h_proxy | 60m | 2023-10-25 a 2026-09-28 | 5.096 | Yahoo ^BVSP |
| ibov_15m_proxy | 15m | 2026-07-06 a 2026-09-28 | 1.665 | Yahoo ^BVSP |
| ibov_5m_proxy | 5m | 2026-07-06 a 2026-09-28 | 4.994 | Yahoo ^BVSP |

## Resultado dos testes de fonte (verificados em 28/09/2026)

| Fonte | Status | Observação |
|---|---|---|
| Yahoo `^BVSP` | ✅ funciona | Proxy do WINFUT (replica Ibov ~1:1 no intraday) |
| Yahoo `WIN=FUT`/`WINFUT` | ❌ não existe | Ticker 404 na API do Yahoo |
| Brapi sem token | ⚠️ parcial | Ações grátis (PETR4 OK); WINFUT exige token gratuito |
| Brapi com token + SDK `brapi` | ✅ integrado | SDK oficial pypi `brapi` 1.6.0 confirmado; requer cadastro brapi.dev |
| `mercados` (scraping B3) | ❌ p/ WINFUT | Boletim/intraday da B3 cobrem só ações: 0 registros WIN em 16.593 (diário) e 9,3M (intraday) |
| ADVFN scraping | ❌ | Bloqueio Cloudflare (403) |
| TradingView tvDatafeed | ❌ | Repositório removido do GitHub |
| **TradingView websocket (protocolo direto)** | ✅ **funciona** | **`scripts/tv_ws_fetch.py` — WIN1! real, sem login, ~15 min atraso** |

## Limitações (importantes)

1. **^BVSP é proxy**: o WINFUT tem base (custo de carry) sobre o Ibov, pequena no
   vencimento próximo. Serve para validar LÓGICA de estratégias e parâmetros em
   pontos do índice. P&L em R$ do WIN (R$ 0,20/pt, contrato de R$ 0,20 por ponto)
   e custos reais exigem dados do contrato.
2. **Yahoo intraday curto**: 5m/15m com janela de ~60 dias; 1h ~730 dias.
3. **62 gaps grandes no diário** (1994–1999, feriados/panes antigas da fonte);
   sem gaps relevantes de 2000 em diante.
4. **Brapi**: histórico de WINFUT depende do plano do token; limite de requisições
   no gratuito.

## Como usar (CLI)

```bash
python3 scripts/data_collector.py yahoo-daily            # baixa/atualiza diário + 1h
python3 scripts/data_collector.py yahoo-intraday 5m      # 1m(7d)/5m/15m/30m(60d)
BRAPI_TOKEN=xxx python3 scripts/data_collector.py brapi-daily   # WINFUT real
python3 scripts/data_collector.py import-csv arquivo.csv daily  # Profit/Tryd/MT5
python3 scripts/data_collector.py validate ibov_daily_proxy
python3 scripts/data_collector.py catalog
python3 scripts/data_collector.py update-all             # p/ agendamento (cron)
```

Importador aceita cabeçalhos PT-BR (Profit: `ABERTUR`, `MAXIM`, `MINIM`,
`ULTIM`, `VOLTOT`) e EN, separador e decimal configuráveis, datas dd/mm/aaaa.

## Próximos passos (Fase 2)

Engine de backtest `backtest_engine.py` sobre a base acima, com custos operacionais
do WIN (corretagem R$ ~1,00-6,00 por contrato, emolumentos B3 ~0,0092% sobre
volume financeiro + slippage 1-2 pts) e métricas completas.
