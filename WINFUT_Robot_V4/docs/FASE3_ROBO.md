# FASE 3 — Robô de Paper Trading (HILO Escadinha v2, WINFUT 10m)

Ativado em 28/09/2026. Componentes:

## Robô paper (OPERACIONAL agora)
- `scripts/winfut_bot.py` — loop contínuo (tmux `winfut_bot`), iteração a cada
  120s dentro do pregão (09:00-17:55 seg-sex). Baixa 5m do WIN1! via TradingView
  (feed anônimo, ~15 min de atraso), reagrupa em 10m e roda a MESMA lógica da
  engine de backtest v2. Entrada paper a mercado; alvo M50; stop estrutural
  (8 candles − 0,5 ATR); eod 17:30.
- `scripts/bot_config.json` — parâmetros + alertas (Telegram opcional).
- `data/winfut/paper_trades.sqlite` — operações paper (auditoria).
- `data/winfut/alerts.log` / `bot.log` — alertas e log do robô.

## Agente desktop (FUTURO — esqueleto pronto)
- `scripts/desktop_agent/vision.py` — visão: captura de tela + template matching.
- `scripts/desktop_agent/executor.py` — mouse/teclado no software trader, com
  dry-run, kill switch e limite de contratos.
- `scripts/desktop_agent/bridge.py` — ponte HTTP local com token e fila
  idempotente de comandos.
- `scripts/desktop_agent/README.md` — instalação no PC e calibração.

## Estados do robô
- Sinal → ALERTA 📐 no alerts.log (e Telegram se configurado).
- Fechamento (alvo/stop/eod) → ALERTA ✅/🛑 com PnL.
- Erro de rede → loga e segue tentando (nunca derruba o processo).

## Limitações conhecidas
1. Feed anônimo ~15 min atrasado (sinais paper chegam atrasados vs corretora).
2. Sandbox pode reiniciar; o robô retoma estado pelo SQLite (sinais_vistos é
   idempotente). Após restart do servidor é preciso religar o tmux:
   `python3 scripts/winfut_bot.py --loop`.
3. Amostra pequena: a estratégia v2 tem PF 2,92 em só 4 trades de backtest —
   o objetivo do robô é exatamente engordar essa amostra com trades paper.
4. NUNCA envia ordem real a qualquer corretora. Sem validação extensiva e
   aprovação explícita, nada além de paper.
