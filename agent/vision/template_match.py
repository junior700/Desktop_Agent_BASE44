"""
template_match.py — Localização de elementos visuais por imagem (OpenCV).

Uso: dado um arquivo de template (print de um botão, ícone etc.),
encontra onde ele está na tela e devolve o centro para clique.
"""

from __future__ import annotations

import os


class TemplateMatcher:
    def __init__(self, screen, confidence: float = 0.8):
        self.screen = screen
        self.confidence = confidence

    def find(self, template_path: str):
        """
        Procura o template na tela.
        Retorna (x, y, score) do centro da melhor correspondência, ou None.
        """
        if not os.path.isfile(template_path):
            raise FileNotFoundError(f"template nao encontrado: {template_path}")

        img = self.screen.capture()
        import cv2  # import tardio
        import numpy as np

        tela = cv2.cvtColor(np.array(img), cv2.COLOR_RGB2BGR)
        template = cv2.imread(template_path, cv2.IMREAD_COLOR)
        if template is None:
            raise ValueError(f"nao foi possivel ler o template: {template_path}")

        # multiescala (0.8x a 1.2x) para tolerar zoom/DPI diferente
        melhor = None  # (score, x, y)
        for escala in (0.8, 0.9, 1.0, 1.1, 1.2):
            dim = (int(template.shape[1] * escala),
                   int(template.shape[0] * escala))
            if dim[0] < 8 or dim[1] < 8 or dim[0] > tela.shape[1]:
                continue
            tpl = cv2.resize(template, dim, interpolation=cv2.INTER_AREA)
            res = cv2.matchTemplate(tela, tpl, cv2.TM_CCOEFF_NORMED)
            _, score, _, loc = cv2.minMaxLoc(res)
            if melhor is None or score > melhor[0]:
                cx = loc[0] + tpl.shape[1] // 2
                cy = loc[1] + tpl.shape[0] // 2
                melhor = (score, cx, cy)

        if melhor and melhor[0] >= self.confidence:
            score, x, y = melhor
            return (x, y, score)
        return None

    def is_on_screen(self, template_path: str, confidence: float = 0.8) -> bool:
        """Condicional: o elemento visual aparece na tela?"""
        achou = self.find(template_path)
        return achou is not None and achou[2] >= confidence
