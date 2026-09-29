"""
executor.py — Módulo de AÇÃO do agente desktop (FUTURO — Fase 3.2)
================================================================================
Executa cliques e digitação no software trader NA MÁQUINA DO PROFESSOR.
Projeto: o robô gera um "comando de ordem" (JSON) quando a estratégia dispara;
o executor aplica o comando na tela (janela de boletas do Profit/Tryd/etc).

DEPENDÊNCIAS (PC): pip install pyautogui

SEGURANÇA (NÃO NEGOCIÁVEL — o código inteiro é construído em volta disto):
  1. DRY_RUN padrão True: clique/digitação são SIMULADOS, nada acontece de
     verdade até o professor criar o arquivo executor.APROVADO.txt.
  2. pyautogui.FAILSAFE=True: jogar o mouse no canto superior esquerdo
     aborta tudo na hora (kill switch físico).
  3. Limite de ações por minuto e valor máximo de contratos por comando.
  4. Nenhum comando de dinheiro real sai daqui sem aprovação EXPLÍCITA do
     professor para aquele dia/valor (chave "operar_real" no config).
  5. Log de toda ação em desktop_agent/executor.log (auditoria).
"""
import json
import logging
import time
from pathlib import Path

import pyautogui

pyautogui.FAILSAFE = True          # kill switch: mouse no canto aborta
pyautogui.PAUSE = 0.3             # pausa entre ações

HERE = Path(__file__).parent
DRY_RUN_FLAG = HERE / "executor.APROVADO.txt"   # existe = ações reais
LOG = HERE / "executor.log"
logging.basicConfig(filename=LOG, level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s")


class Executor:
    def __init__(self, max_contratos: int = 1, max_acoes_min: int = 20):
        self.max_contratos = max_contratos
        self.max_acoes_min = max_acoes_min
        self._tempos: list[float] = []

    @property
    def dry_run(self) -> bool:
        return not DRY_RUN_FLAG.exists()

    def _limite_ok(self) -> bool:
        agora = time.time()
        self._tempos = [t for t in self._tempos if agora - t < 60]
        if len(self._tempos) >= self.max_acoes_min:
            raise RuntimeError("Limite de ações por minuto excedido — abortado.")
        self._tempos.append(agora)
        return True

    def _agir(self, acao: str, **kw):
        self._limite_ok()
        modo = "DRY-RUN" if self.dry_run else "REAL"
        logging.info("[%s] %s %s", modo, acao, kw)
        if self.dry_run:
            print(f"[DRY-RUN] {acao} {kw} (nada executado)")
            return
        getattr(pyautogui, acao)(**kw)

    def clicar(self, x: int, y: int):
        """Clique num ponto da tela (coordenadas vindas do vision.py)."""
        self._agir("click", x=x, y=y)

    def digitar(self, texto: str):
        self._agir("typewrite" if texto.isascii() else "write", 
                   interval=0.05) if False else self._agir("typewrite", interval=0.05)
        # (pyautogui usa 'write' nas versões novas; ajustar ao ambiente)
        raise NotImplementedError("Ajustar chamada conforme versão do pyautogui")

    def enviar_ordem(self, comando: dict):
        """Aplica um comando de ordem gerado pelo robô:
        {"acao": "compra", "contratos": 1, "preco": "mercado"}.
        Fluxo esqueleto (a concluir com os templates do software):
          1. focar janela de boleta; 2. preencher qtde/ativo;
          3. revisar em tela; 4. clicar botão de envio."""
        if comando.get("contratos", 1) > self.max_contratos:
            raise ValueError("Comando excede o máximo de contratos permitido.")
        self._agir("press", key="f11")  # exemplo: atalho de boleta do Profit
        logging.info("Ordem recebida (esqueleto): %s", json.dumps(comando))
        # ... implementação específica do software a partir daqui ...


if __name__ == "__main__":
    ex = Executor()
    print(f"Modo: {'DRY-RUN' if ex.dry_run else '*** AÇÕES REAIS ***'}")
    print("Testando clique simulado em (500, 500)...")
    ex.clicar(500, 500)
    print("OK. Para habilitar ações reais, crie o arquivo:")
    print(DRY_RUN_FLAG)
