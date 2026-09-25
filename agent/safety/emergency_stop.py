"""
emergency_stop.py — Parada de emergência via ESC 3x.

Listener independente (thread própria via pynput). Uma vez disparado,
só reinicia manualmente (reset() chamado pelo usuário no dashboard).
O guardrail consulta is_triggered() e bloqueia TUDO depois do disparo.
"""

from __future__ import annotations

import threading
import time


class EmergencyStop:
    """
    Contador de ESC dentro de uma janela de tempo.
    test_mode=True permite simular pressionamentos sem pynput (testes/CI).
    """

    def __init__(self, presses_required: int = 3, window_s: float = 1.5,
                 test_mode: bool = False):
        self.presses_required = presses_required
        self.window_s = window_s
        self._press_times: list[float] = []
        self._triggered = False
        self._listener = None
        self._test_mode = test_mode
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    def start(self) -> bool:
        """Inicia o listener global de teclado. Retorna True se ativo."""
        if self._test_mode or self._listener is not None:
            return True
        try:
            from pynput import keyboard  # import tardio: só no Windows/runtime
        except ImportError:
            # Sem pynput o stop manual por tecla fica indisponível;
            # o dashboard ainda pode chamar trigger().
            return False

        def on_press(key):
            if key == keyboard.Key.esc:
                self.register_press()

        self._listener = keyboard.Listener(on_press=on_press)
        self._listener.daemon = True
        self._listener.start()
        return True

    def stop(self) -> None:
        if self._listener is not None:
            self._listener.stop()
            self._listener = None

    # ------------------------------------------------------------------
    def register_press(self) -> None:
        """Registra um ESC. Dispara se atingir o limite dentro da janela."""
        with self._lock:
            now = time.monotonic()
            self._press_times = [t for t in self._press_times
                                 if now - t < self.window_s]
            self._press_times.append(now)
            if len(self._press_times) >= self.presses_required:
                self.trigger()

    def trigger(self) -> None:
        """Dispara manualmente (dashboard, teste, etc.). Irreversível até reset()."""
        self._triggered = True

    def is_triggered(self) -> bool:
        return self._triggered

    def reset(self) -> None:
        """Só o usuário deve chamar (botão no dashboard), nunca um roteiro."""
        self._triggered = False
        with self._lock:
            self._press_times.clear()
