"""
vision.py — Módulo de VISÃO do agente desktop (FUTURO — Fase 3.2)
================================================================================
Roda NO COMPUTADOR DO PROFESSOR (Windows), junto ao software trader (Profit,
Tryd, MetaTrader etc.). Captura a tela, localiza elementos do software por
template matching (OpenCV) e extrai informação visual (posição do cursor de
cotação, cor do candle, valores de book). No futuro, os screenshots podem ser
enviados ao Superagent para leitura por visão de IA.

DEPENDÊNCIAS (instalar no PC): pip install mss opencv-python numpy pillow

SEGURANÇA: este módulo é SOMENTE LEITURA — não move mouse nem digita nada.
"""
import time
from pathlib import Path

import cv2
import numpy as np

try:
    from mss import mss
except ImportError:
    mss = None  # fallback: pillow ImageGrab

TEMPLATES_DIR = Path(__file__).parent / "templates"  # .png dos elementos
TEMPLATES_DIR.mkdir(exist_ok=True)


def capture(region: dict | None = None) -> np.ndarray:
    """Captura a tela (ou região {'left','top','width','height'}) como BGR."""
    if mss is not None:
        with mss() as s:
            img = np.array(s.grab(region or s.monitors[1]))
            return img[:, :, :3]  # descarta canal alpha
    from PIL import ImageGrab
    return np.array(ImageGrab.grab(bbox=None if not region else (
        region["left"], region["top"],
        region["left"] + region["width"], region["top"] + region["height"])))


def find_template(screen: np.ndarray, name: str, threshold: float = 0.85):
    """Localiza um elemento salvo em templates/<name>.png na tela.
    Retorna (cx, cy, score) do melhor match ou None."""
    path = TEMPLATES_DIR / f"{name}.png"
    if not path.exists():
        raise FileNotFoundError(
            f"Template {path} não existe — tire um print do elemento e salve ali.")
    tpl = cv2.imread(str(path), cv2.IMREAD_COLOR)
    res = cv2.matchTemplate(screen, tpl, cv2.TM_CCOEFF_NORMED)
    _, score, _, loc = cv2.minMaxLoc(res)
    if score < threshold:
        return None
    h, w = tpl.shape[:2]
    return (loc[0] + w // 2, loc[1] + h // 2, float(score))


def read_chart_state(screen: np.ndarray) -> dict:
    """Extrai um resumo VISUAL do gráfico aberto no software trader.
    ESQUELETO: implementar com os templates do software escolhido
    (botão compra/venda, campo quantidade, valor do último negócio...)."""
    state = {"ts": time.time(), "found": {}}
    for name in ("btn_compra", "btn_venda", "campo_qtd", "preco_ultimo"):
        try:
            r = find_template(screen, name)
        except FileNotFoundError:
            r = None
        state["found"][name] = r
    return state


if __name__ == "__main__":
    print("Capturando tela em 3s... (mantenha o software trader visível)")
    time.sleep(3)
    s = read_chart_state(capture())
    print(s)
