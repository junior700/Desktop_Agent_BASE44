# Agente Desktop — Visão e Controle do Software Trader (Fase 3.2, futuro)

Rodar **no computador do professor** (Windows), junto ao software trader
(Profit, Tryd, MetaTrader, HOME Broker etc.).

## Arquitetura

```
[Robô winfut_bot.py — nuvem/sandbox]          [PC do professor]
        sinal de trade ──comando JSON──▶ bridge.py (FastAPI local)
                                             │
                          vision.py ◀───────┤ (lê a tela)
                          (captura/OCR)      │
                          executor.py ◀──────┘ (clica/digita no software)
```

- **vision.py** — SOMENTE LEITURA: captura a tela (mss), localiza elementos
  (botões de compra/venda, campos) por template matching OpenCV, e no futuro
  envia screenshots para o Superagent ler com visão de IA.
- **executor.py** — AÇÃO: clica/digita no software trader. **Dry-run por
  padrão**; só opera de verdade se o professor criar o arquivo
  `executor.APROVADO.txt`. Kill switch: mouse no canto da tela aborta tudo.
- **bridge.py** — ponte: servidor HTTP local com token, fila idempotente de
  comandos (nunca executa o mesmo comando duas vezes).

## Instalação (no PC)

```bash
pip install mss opencv-python numpy pillow pyautogui fastapi uvicorn
python bridge.py          # mostra o token; escuta em 127.0.0.1:8765
```

## Calibração (uma vez, por software)

1. Tire prints dos elementos (botão COMPRA, botão VENDA, campo quantidade,
   preço atual) e salve em `templates/*.png`.
2. Rode `python vision.py` para conferir se os templates são encontrados.
3. Rode `python executor.py` em DRY-RUN e acompanhe o log.

## Caminho até operar real (SOB APROVAÇÃO EXPLÍCITA DO PROFESSOR)

1. Robô paper gera comandos → bridge aplica em boleta DEMO do software.
2. ~2-4 semanas de demonstração registrada (executor.log + paper_trades.sqlite).
3. Professor decide, por escrito, se autoriza dinheiro real, valor máximo e
   limite diário → só então o `executor.APROVADO.txt` é criado.

## O que NÃO está pronto (honestidade)

- Templates visuais específicos (dependem do software escolhido).
- O túnel nuvem→PC (o Base44 precisa de conector/webhook público ou o PC
  expõe a ponta via serviço de túnel seguro, ex. Cloudflare Tunnel).
- Envio de ordem real: intencionalmente `NotImplementedError` até a
  aprovação.
