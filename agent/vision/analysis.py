"""
analysis.py — Reconhecimento programático de imagem: COR e GEOMETRIA.

Três capacidades de visão do agente:
    1. OCR            (ocr.py — texto na tela, localizar texto)
    2. Cromática      (este módulo — achar cor, com tolerância)
    3. Geometria      (este módulo — achar formas por contornos, OpenCV)

Referências / base técnica:
    - OpenCV oficial: docs.opencv.org (findContours, approxPolyDP, inRange)
      opencv/opencv no GitHub (>70k stars, mantido pela OpenCV.org)
    - Guia "Shape Detection" pyimagesearch.com/2016/02/08/opencv-shape-detection/
      (padrão consolidado da comunidade para detecção por contornos)

DESIGN:
    - find_color tem DOIS caminhos: rápido (numpy+cv2, quando disponível)
      e fallback puro PIL (lento mas sem dependência extra, e testável
      em qualquer ambiente). Mesmo resultado: centro do aglomerado da cor.
    - find_shapes exige OpenCV (import tardio, sobe exceção clara).
"""

from __future__ import annotations

from typing import Optional


def _parse_cor(cor: str) -> tuple[int, int, int]:
    """
    Aceita "r,g,b" (ex.: "255,0,0") ou "#rrggbb" (ex.: "#ff0000").
    Retorna tupla RGB. Levanta ValueError em formato inválido.
    """
    s = str(cor).strip().lower().replace(" ", "")
    if s.startswith("#"):
        s = s[1:]
        if len(s) == 3:  # #f00 -> #ff0000
            s = "".join(c * 2 for c in s)
        if len(s) != 6:
            raise ValueError(f"cor hex invalida: {cor!r}")
        return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))
    partes = s.split(",")
    if len(partes) != 3:
        raise ValueError(f"cor deve ser 'r,g,b' ou '#rrggbb': {cor!r}")
    rgb = tuple(int(p) for p in partes)
    if any(v < 0 or v > 255 for v in rgb):
        raise ValueError(f"canal fora de 0-255 em: {cor!r}")
    return rgb  # type: ignore[return-value]


class ScreenAnalyzer:
    """
    Análise cromática e geométrica da tela.

    screen: ScreenController (captura) — injetável p/ testes.
    Rota analítica: image passável por parâmetro (testes com PIL sintética).
    """

    def __init__(self, screen, stride: int = 4):
        self.screen = screen
        self.stride = max(1, int(stride))  # fallback PIL: pula pixels p/ velocidade

    # ==================================================================
    # CROMÁTICA
    # ==================================================================
    def find_color(self, cor: str, tolerancia: int = 30,
                   image=None) -> Optional[tuple[int, int]]:
        """
        Centro do maior aglomerado da cor na imagem/tela, ou None.

        tolerancia: desvio máximo por canal (0-255). 30 é o default do
        projeto (config.color_tolerance).
        """
        img = image if image is not None else self.screen.capture()
        alvo = _parse_cor(cor)
        tol = max(0, min(255, int(tolerancia)))
        try:
            return self._find_color_cv2(img, alvo, tol)
        except ImportError:
            return self._find_color_pil(img, alvo, tol)

    def _find_color_cv2(self, img, alvo, tol):
        """Caminho rápido: máscara numpy + maior contorno (OpenCV)."""
        import cv2
        import numpy as np
        arr = np.asarray(img.convert("RGB")) if hasattr(img, "convert") else np.asarray(img)
        baixo = np.array([max(0, c - tol) for c in alvo], dtype=np.uint8)
        alto = np.array([min(255, c + tol) for c in alvo], dtype=np.uint8)
        mask = cv2.inRange(arr, baixo, alto)
        contornos, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL,
                                         cv2.CHAIN_APPROX_SIMPLE)
        if not contornos:
            return None
        maior = max(contornos, key=cv2.contourArea)
        m = cv2.moments(maior)
        if m["m00"] == 0:
            return None
        return (int(m["m10"] / m["m00"]), int(m["m01"] / m["m00"]))

    def _find_color_pil(self, img, alvo, tol) -> Optional[tuple[int, int]]:
        """
        Fallback puro PIL: varre pixels com stride, agrupa por centroides
        ponderados. Sem dependências extras — caminho testável em CI.
        """
        import PIL.Image
        if not isinstance(img, PIL.Image.Image):
            img = PIL.Image.fromarray(img)
        rgb = img.convert("RGB")
        w, h = rgb.size
        px = rgb.load()
        r0, g0, b0 = alvo
        soma_x = soma_y = total = 0
        for y in range(0, h, self.stride):
            for x in range(0, w, self.stride):
                r, g, b = px[x, y][:3]
                if abs(r - r0) <= tol and abs(g - g0) <= tol and abs(b - b0) <= tol:
                    soma_x += x
                    soma_y += y
                    total += 1
        if total == 0:
            return None
        return (soma_x // total, soma_y // total)

    # ==================================================================
    # GEOMETRIA (OpenCV obrigatório)
    # ==================================================================
    def find_shapes(self, forma: str, image=None,
                    area_min: int = 200) -> list[dict]:
        """
        Formas na imagem/tela por contornos + approxPolyDP.

        forma: "retangulo" | "circulo" | "triangulo"
        Retorna lista de {"centro": (x, y), "area": int} (ordem por área).
        Requer OpenCV — no Windows o projeto já lista opencv-python.
        """
        import cv2  # import tardio; sobe ImportError com mensagem clara
        import numpy as np
        img = image if image is not None else self.screen.capture()
        if hasattr(img, "convert"):  # PIL -> array RGB
            img = np.asarray(img.convert("RGB"))
        gray = cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)
        _, bin_ = cv2.threshold(gray, 200, 255, cv2.THRESH_BINARY_INV)
        contornos, _ = cv2.findContours(bin_, cv2.RETR_EXTERNAL,
                                        cv2.CHAIN_APPROX_SIMPLE)
        achados: list[dict] = []
        alvo = str(forma).strip().lower()
        for c in contornos:
            area = cv2.contourArea(c)
            if area < area_min:
                continue
            perim = cv2.arcLength(c, True)
            aprox = cv2.approxPolyDP(c, 0.02 * perim, True)
            m = cv2.moments(c)
            if m["m00"] == 0:
                continue
            centro = (int(m["m10"] / m["m00"]), int(m["m01"] / m["m00"]))
            n = len(aprox)
            if alvo in ("retangulo", "quadrado") and n == 4:
                achados.append({"centro": centro, "area": int(area)})
            elif alvo == "triangulo" and n == 3:
                achados.append({"centro": centro, "area": int(area)})
            elif alvo in ("circulo", "elipse"):
                circular = 4 * 3.14159 * area / (perim * perim) if perim else 0
                if circular > 0.8:  # círculos têm circularidade ~1
                    achados.append({"centro": centro, "area": int(area)})
        achados.sort(key=lambda d: -d["area"])
        return achados

    def find_shape(self, forma: str, image=None,
                   area_min: int = 200) -> Optional[dict]:
        """Maior forma do tipo pedido, ou None."""
        achados = self.find_shapes(forma, image=image, area_min=area_min)
        return achados[0] if achados else None

    # ------------------------------------------------------------------
    # Booleanos p/ condicionais do interpretador
    # ------------------------------------------------------------------
    def color_on_screen(self, cor: str, tolerancia: int = 30) -> bool:
        return self.find_color(cor, tolerancia) is not None

    def shape_on_screen(self, forma: str, area_min: int = 200) -> bool:
        return self.find_shape(forma, area_min=area_min) is not None

