"""
mouse.py — Controle de mouse (cliques e posicionamento).

DIRETRIZ DO PROJETO: a trajetória do mouse não importa.
Movimento entre cliques = teleporte direto (moveTo).
O que importa: coordenada do clique, botão, e intervalo entre cliques.

O backend real é o pyautogui (import tardio — só quando o agente roda
de verdade no Windows). O FAILSAFE do pyautogui fica LIGADO: levar o mouse
ao canto superior esquerdo da tela também interrompe o pyautogui.
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
            import pyautogui  # import tardio: só no Windows/runtime real
            pyautogui.FAILSAFE = True  # canto da tela = aborto extra (mantém)
            pyautogui.PAUSE = 0.1
            self._backend = pyautogui
        return self._backend

    # ------------------------------------------------------------------
    def move(self, x: int, y: int) -> None:
        """Teleporta o mouse para (x, y). Sem trajetória, sem suavização."""
        self.backend.moveTo(int(x), int(y))

    def click(self, x: Optional[int] = None, y: Optional[int] = None,
              button: str = "left", clicks: int = 1,
              interval_s: float = 0.0) -> None:
        """Clica. Se der coordenada, teleporta antes (1 movimento, 0 física)."""
        if x is not None and y is not None:
            self.move(x, y)
        if interval_s > 0:
            import time
            time.sleep(interval_s)
        self.backend.click(clicks=clicks, button=button, interval=0.05)

    def double_click(self, x: Optional[int] = None, y: Optional[int] = None) -> None:
        self.click(x, y, button="left", clicks=2, interval_s=0.05)

    def right_click(self, x: Optional[int] = None, y: Optional[int] = None) -> None:
        self.click(x, y, button="right")

    def position(self) -> tuple[int, int]:
        """Posição atual do cursor (usado pelo dashboard/recorder)."""
        return tuple(self.backend.position())
