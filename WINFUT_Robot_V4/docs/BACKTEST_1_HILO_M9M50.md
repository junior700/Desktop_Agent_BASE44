# Backtest #1 — HILO Escadinha + Rompimento M9 (compra) — WINFUT

Data: 28/09/2026 | Engine: `scripts/backtest_engine.py` | Base: TradingView BMFBOVESPA:WIN1! real

## Regras testadas (conforme especificado)

**Contexto (setup):** M9 < M50, M50 < M200, M9 com trajetória descendente,
HILO(3) vermelha, gap M50−M9 ≥ mínimos (ganho potencial).

**Gatilho:** candle fecha acima da M9 e vira a M9 para ascendente → compra a
mercado na abertura do candle seguinte.

**Alvo:** M50 dinâmica. **Stop:** mínimo estrutural de 8 candles − 0,5×ATR14.
**Day trade:** saída no fechamento a partir de 17h30. Stop tem prioridade quando
alvo e stop caem no mesmo candle (conservador).

**Custos:** R$ 0,20/pt, slippage 1 pt/perna, corretagem R$ 3,00/perna,
emolumentos 0,0092%. Capital R$ 10.000, 1 contrato.

## Resultados

| Métrica | 10m (ago–set/26) | 15m (mar–set/26) | Diário (2011–21) |
|---|---|---|---|
| Trades | 5 | 16 | 4 |
| Win rate | 20% | 43,8% | 75% |
| PnL total (pts) | −1.388 | −632 | +7.898 |
| PnL (R$) | −339 | −328 | +1.545 |
| Payoff (ganho/perda) | 0,39 | 1,11 | 1,07 |
| Profit factor | 0,10 | 0,87 | 3,20 |
| Expectância/trade | −278 pts | −40 pts | +1.975 pts |
| Max DD | 1,5% | 9,1% | 5,9% |
| Máx. perdas seguidas | 3 | 7 | 1 |
| Saídas alvo/stop/eod | 0/2/3 | 4/6/6 | 3/1/0 |

## Veredito

**NO PERÍODO TESTADO, A ESTRATÉGIA NÃO VALIDA.** Expectância negativa no
intradiário (PF 0,10 no 10m; 0,87 no 15m). O resultado positivo no diário vem de
apenas 4 trades em 10 anos — sem significância estatística.

## Diagnóstico dos problemas

1. **Stop largo demais vs. alvo**: perda média 525–662 pts vs. ganho médio
   148–585 pts. O mínimo estrutural de 8 candles no WINFUT fica longe; quando o
   repique falha, o prejuízo engole 2 bons trades.
2. **Contratendência**: comprar repique rumo a uma M50 descendente é pescar
   contra o viés (M9<M50<M200). O alvo "anda para baixo" junto com o preço.
3. **Saídas no EOD negativas**: 6 de 16 trades no 15m fecharam no fim do dia
   ainda abaixo do alvo — o repique não teve tempo de completar.
4. **Amostra pequena**: 5–16 trades intradiário. A TV anônima só entrega ~5.000
   barras; o 10m cobre só 2 meses (limitação da base atual).

## Sensibilidade (anti-overfitting, 10m)

Grid min_gap {0,100,200,300} × ATR mult {0,25, 0,5, 1,0}: todos os combos
negativos (PF 0,08–0,11). O resultado ruim não é artefato de um parâmetro
isolado — é a estrutura da operação.

## Gráficos

`docs/figs/winfut_{10m,15m,diario}_equity.png`, `..._pnl_hist.png`, `..._gap_scatter.png`

## Hipóteses de melhoria (para próximo teste, se o professor aprovar)

1. **Stop mais curto**: estrutura de 3–5 candles, ou stop = 1×ATR, priorizando
   gap ≥ 1,5× stop (o filtro RR existe na engine).
2. **Confirmar HILO verde** no gatilho (alinhamento de momentum) em vez de
   exigir escadinha vermelha.
3. **Alvo parcial** em 50% do gap + trail no restante.
4. **Mais dados**: exportar histórico 10m do Profit (o importador CSV já aceita)
   ou assinar dados TV para walk-forward honesto.

---

## VERSÃO 2 (28/09/2026) — Reversão do HILO para verde + travado no 10m

Condição nova do professor: o gatilho exige a **reversão do HILO para verde** no
candle do rompimento (setup continua exigindo escadinha vermelha no candle
anterior). **Timeframe travado em 10m** — fora dele a estratégia não funciona
(confirmado empiricamente: PF 1,01 no 15m, embora não seja critério).

### Resultado 10m (27/07 a 28/09/2026)

| Métrica | Valor |
|---|---|
| Trades | 4 |
| Win rate | 50% |
| PnL total | +1.099 pts (R$ +169) |
| Payoff | 2,92 |
| Profit factor | 2,92 |
| Expectância | +275 pts/trade |
| Max DD | 0,4% (R$ 40) |
| Sharpe (diário) | 4,79 |
| Saídas | alvo/stop/eod: ver trades_winfut_10m.csv |

### Sensibilidade (12 combos): TODOS positivos, PF 2,39–3,29
Estável quanto a parâmetros de stop e gap — mas são os mesmos 4 trades em todos
os combos. A direcão é consistente; a amostra é minúscula.

### Limitação crítica e caminhos
Só existem 2 meses de candles de 10m (TV anônima limita ~5.000 barras de 5m).
Para validar de verdade, precisamos de mais histórico 10m:
1. Exportar 10m do Profit/Tryd (importador CSV pronto) — meses ou anos;
2. Acumulação diária automática (workflow baixa 5m → reagrupa 10m a cada dia);
3. Paper trading da estratégia (Fase 3) para amostra viva.

**Status: PROMISSORA, PORÉM NÃO VALIDADA** — 4 trades não comprovam nada.
