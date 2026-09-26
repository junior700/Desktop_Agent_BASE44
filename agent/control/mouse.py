"""
mouse.py - Controle de mouse (cliques e posicionamento).

DIRETRIZ DO PROJETO: a trajetoria do mouse nao importa.
Movimento entre cliques = teleporte direto (moveTo).
O que importa: coordenada do clique, botao, e intervalo entre cliques.

O backend real e o pyautogui (import tardio - so quando o agente roda
de verdade no Windows). O FAILSAFE do pyautogui fica LIGADO: levar o mouse
ao canto superior esquerdo da tela tambem interrompe o pyautogui.
"""

from __future__ import annotations

from typing import Optional


class MouseController:
    def __init__(self, backend=None):
        """backend: objeto com moveTo/click/position (pyautogui ou fake p/ testes)."""
        self._backend = backend

    @property
    def backend(self):
        if self._backend is None:
            import pyautogui  # import tardio: so no Windows/runtime real
            pyautogui.FAILSAFE = True  # canto da tela = aborto extra (mantem)
            pyautogui.PAUSE = 0.1
            self._backend = pyautogui
        return self._backend

    # ------------------------------------------------------------------
    def move(self, x: int, y: int) -> None:
        """Teleporta o mouse para (x, y). Sem trajetoria, sem suavizacao."""
        self.backend.moveTo(int(x), int(y))

    def click(self, x: Optional[int] = None, y: Optional[int] = None,
              button: str = "left", clicks: int = 1,
              interval_s: float = 0.0) -> None:
        """Clica. Se der coordenada, teleporta antes (1 movimento, 0 fisica)."""
        if x is not None and y is not None:
            self.move(x, y)
        if interval_s > 0:
            import time
            time.sleep(interval_s)
        self.backend.click(clicks=clicks, button=button, interval=0.05)

    def double_click(self, x: Optional[int] = None, y: Optional[int] = None) -> None:
        self.click(x, y, button="left", clicks=2, interval_s=0.05)

    def right_click(self, x: Optional[int] = None, y: Optional[int] = None,
                    settle_s: float = 0.05, hold_s: float = 0.05) -> None:
        """Clique direito com settle apos o teleporte e hold real.

        BUG REAL (26/09/2026): o replay usava click(button='right')
        imediatamente apos o moveTo - down+up na MESMA batelada logo
        apos SetCursorPos. Menu de contexto do Windows dispara no
        mouse UP (WM_CONTEXTMENU); pressao de zero ms pode ser
        ignorada pelo app alvo (clique gravado nao abriu o menu na
        reproducao). 50ms de settle (posicao assentar antes de
        pressionar) + 50ms de hold (pressao de verdade antes de
        soltar) = janela humana confiavel. Ainda teleporte, sem
        trajetoria. Parametros injetaveis p/ testes instantaneos.
        """
        if x is not None and y is not None:
            self.move(x, y)
        import time
        if settle_s > 0:
            time.sleep(settle_s)
        self.backend.mouseDown(button="right")
        if hold_s > 0:
            time.sleep(hold_s)
        self.backend.mouseUp(button="right")

    def position(self) -> tuple[int, int]:
        """Posicao atual do cursor (usado pelo dashboard/recorder)."""
        return tuple(self.backend.position())
