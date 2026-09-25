"""
screen.py — Captura de tela com fallback em 3 camadas.

Padrão já validado no projeto antigo do usuário:
1. pyautogui.screenshot()   (preferido)
2. mss                      (mais rápido, multi-monitor)
3. PIL.ImageGrab            (último recurso)

Retorna uma imagem PIL; quem chama decide salvar ou não.
"""

from __future__ import annotations


class ScreenController:
    def __init__(self, capture_fn=None):
        """capture_fn: função () -> PIL.Image (injetável para testes)."""
        self._capture_fn = capture_fn
        self._last_error = ""

    @property
    def last_error(self) -> str:
        return self._last_error

    def capture(self):
        """
        Captura a tela inteira. Tenta pyautogui -> mss -> PIL.
        Levanta RuntimeError se todas falharem.
        """
        if self._capture_fn is not None:
            return self._capture_fn()

        # 1) pyautogui
        try:
            import pyautogui
            return pyautogui.screenshot()
        except Exception as e:  # noqa: BLE001 — fallback proposital
            self._last_error = f"pyautogui falhou: {e}"

        # 2) mss
        try:
            import mss
            with mss.mss() as sct:
                monitor = sct.monitors[0]
                raw = sct.grab(monitor)
                from PIL import Image
                return Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
        except Exception as e:  # noqa: BLE001
            self._last_error += f" | mss falhou: {e}"

        # 3) PIL.ImageGrab
        try:
            from PIL import ImageGrab
            return ImageGrab.grab()
        except Exception as e:  # noqa: BLE001
            self._last_error += f" | PIL.ImageGrab falhou: {e}"
            raise RuntimeError(
                f"Todas as camadas de captura falharam: {self._last_error}")

    def capture_to_file(self, path: str):
        """Captura e salva em arquivo. Retorna a imagem."""
        img = self.capture()
        img.save(path)
        return img

    @staticmethod
    def size() -> tuple[int, int]:
        """Tamanho real da tela via pyautogui (para o guardrail)."""
        import pyautogui
        return pyautogui.size()
