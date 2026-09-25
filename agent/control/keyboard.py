"""
keyboard.py — Controle de teclado (digitação humanizada + hotkeys).

Backend real: pyautogui (import tardio). Delays humanizados por tecla.
"""

from __future__ import annotations

import random
import time


class KeyboardController:
    def __init__(self, backend=None, delay_min_ms: int = 60,
                 delay_max_ms: int = 180, sleep_fn=time.sleep):
        self._backend = backend
        self.delay_min_ms = delay_min_ms
        self.delay_max_ms = delay_max_ms
        self._sleep = sleep_fn  # injetável para testes rápidos

    @property
    def backend(self):
        if self._backend is None:
            import pyautogui
            pyautogui.PAUSE = 0.05
            self._backend = pyautogui
        return self._backend

    # ------------------------------------------------------------------
    def type_text(self, texto: str) -> None:
        """Digita texto com atraso aleatório entre teclas (humanizado)."""
        for ch in str(texto):
            self.backend.press(ch)
            delay = random.uniform(self.delay_min_ms, self.delay_max_ms) / 1000.0
            self._sleep(delay)

    def press_combo(self, combinacao: str) -> None:
        """
        Pressiona combo tipo "ctrl+s", "win+r", "enter", "esc".
        As teclas já passaram pelo guardrail ANTES de chegar aqui.
        """
        keys = [k.strip().lower() for k in combinacao.split("+") if k.strip()]
        if not keys:
            return
        if len(keys) == 1:
            self.backend.press(keys[0])
        else:
            self.backend.hotkey(*keys)
