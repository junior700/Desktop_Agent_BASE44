# WINFUT Paper Trading Bot — Pacote v3 (v4 estratégias)
Data: 28/09/2026 | Operação exclusivamente PAPER (sem dinheiro real)

## Estratégias ativas
1. LONG (HILO escadinha v3): regime M9<M50<M200, HILO(3) verde no gatilho,
   rompimento da M9 virando, filtros anti-esticada + room até alvo.
   Alvo M50+150 pts | Stop mínimo 8 candles - 0,5 ATR | EOD 17:30.
2. SHORT PERNADA (v4): mesmo regime, fechamento >= M50+300 pts (exaustão),
   entrada vendida no fechamento | Alvo M50 dinâmica | Stop máxima+0,5 ATR | EOD.
   Handoff natural: comprado sai em M50+150, pernada assume em M50+300.

## Arquivos principais
- scripts/winfut_bot.py ............ robô (loop 120s, WS TradingView, SQLite paper)
- scripts/backtest_engine.py ........ engine de backtest (v2/v3/v4, custos B3)
- scripts/tv_ws_fetch.py ............ coletor de dados (WIN1!/WDO1!, 5m/15m/1D)
- scripts/bot_config.json ........... parâmetros operacionais (um só arquivo)
- data/winfut/ ...................... bases parquet (5m/15m/10m derivado/1D)
- docs/ ............................. relatórios de validação
- desktop_agent/ .................... agente de visão (Profit) + execução (Agora)

## Instalacao (Windows) — uma vez so
1. Instale o Python 3.10+ (python.org, marque "Add to PATH")
2. PowerShell: powershell -NoProfile -ExecutionPolicy Bypass -File setup_ambiente.ps1
   (cria o .venv e instala o requirements.txt com as versoes validadas)
   Manual: python -m venv .venv && .venv\Scripts\python.exe -m pip install -r requirements.txt
3. Rode o painel: dashboard_robo.ps1 (usa o .venv automaticamente)

## Como rodar
pip install pandas numpy pyarrow websockets
python3 scripts/winfut_bot.py --loop     # robô em loop (120s)
python3 scripts/winfut_bot.py --once    # uma iteração (teste)

## Pendências declaradas
- Custos reais da corretora Agora não calibrados (modelo padrão B3 em uso)
- Calibração visual dos templates do desktop_agent com o Profit
- Marcador "M9-abort" em modo sombra (não altera saída real)

## Painel de controle (Windows)
- dashboard_robo.ps1 ......... menu interativo: iniciar/parar robô, status,
  log ao vivo, operações do paper, resumo win/pts/R$, iteração única e update de dados.
- scripts/ps_bridge.py ....... ponte que lê o SQLite/alertas para o dashboard.
Como abrir: botão direito no dashboard_robo.ps1 -> "Executar com PowerShell",
ou crie um start_dashboard.bat com estas 3 linhas na raiz do projeto:

    @echo off
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dashboard_robo.ps1"
    pause

(O .bat não vem no zip por política de segurança de arquivos do Base44 - cole as
linhas acima no Bloco de Notas e salve como start_dashboard.bat.)

## Troubleshooting: o painel pisca e fecha / nao abre
Causa mais comum: arquivos extraidos de um zip baixado da internet carregam a
marca "zona de internet" (Mark of the Web) e o PowerShell bloqueia execucao.

Fix rapido (escolha um):
1. Botao direito no dashboard_robo.ps1 -> Propriedades -> marcar "Desbloquear"
   (ou "Unblock") na base da janela -> OK.
2. Ou, num PowerShell aberto na pasta do projeto:
   Get-ChildItem *.ps1 | Unblock-File ; .\dashboard_robo.ps1
3. Ou rode pelo start_dashboard.bat com o .ps1 atualizado (ja faz o unblock sozinho).

Para VER o erro (se ainda nao abrir): abra o PowerShell, navegue ate a pasta e
rode manualmente - a mensagem fica na tela:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\dashboard_robo.ps1

## Alertas: popup nativo do Windows (estilo OCO)
Cada evento do robô abre uma janela de diálogo do Windows (MessageBox nativo,
com som do sistema, sempre na frente) além de gravar em alerts.log:
- SINAL COMPRA: mostra a compra + as duas VENDAS de proteção (stop e alvo)
  prontas para montar o OCO no Profit manualmente.
- SINAL VENDA (pernada): mostra a venda + as duas COMPRAS de proteção.
- ALVO / STOP / EOD: mostra o resultado em pts e R$ da operação fechada.
O popup não bloqueia o robô (processo separado). Em Linux apenas registra log.
Para o robô operar a conta de verdade no Profit, o caminho é o desktop_agent
(visão computacional + execução), que segue pendente de calibração.

## Painel GRAFICO (winfut_gui.ps1) — janela nativa do Windows
O start_dashboard.bat agora abre uma janela de verdade (WinForms, sem novas
dependencias): menu no topo (Robo/Ver/Ajuda) + area de texto com o log do robo
AO VIVO (atualiza a cada 2s) + barra de status (ATIVO/PARADO).
- F5 inicia o robo, F6 para. Fechar o painel NAO para o robo.
- Popups OCO continuam aparecendo sobre tudo (sinal, stop, alvo, EOD).
- O painel de console antigo (dashboard_robo.ps1) segue no pacote como alternativa.
