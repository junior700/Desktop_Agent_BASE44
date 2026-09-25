"""
ocr.py — Leitura de texto da tela (Tesseract via pytesseract).

Import tardio: pytesseract + binário Tesseract só entram em runtime real.
Injeção de engine para testes (fake que retorna texto pré-definido).
"""

from __future__ import annotations

from typing import Optional


class FakeOCREngine:
    """Para testes: retorna texto fixo, ignora a imagem."""
    def __init__(self, text: str = ""):
        self.text = text

    def read_text(self, image) -> str:
        return self.text


class TesseractOCREngine:
    """Engine real. Requer pytesseract + binário Tesseract instalado."""
    def __init__(self, tesseract_cmd: Optional[str] = None, lang: str = "por+eng"):
        import pytesseract  # import tardio
        if tesseract_cmd:
            pytesseract.pytesseract.tesseract_cmd = tesseract_cmd
        self._pt = pytesseract
        self.lang = lang

    def read_text(self, image) -> str:
        return self._pt.image_to_string(image, lang=self.lang)

    def read_words(self, image) -> list[dict]:
        """Palavras com caixas (x, y, centro) — para clicar em texto."""
        import pytesseract
        data = pytesseract.image_to_data(
            image, lang=self.lang, output_type=pytesseract.Output.DICT)
        words = []
        for i, txt in enumerate(data["text"]):
            txt = txt.strip()
            if not txt or int(data["conf"][i]) < 40:
                continue
            x, y, w, h = (data["left"][i], data["top"][i],
                          data["width"][i], data["height"][i])
            words.append({"texto": txt.lower(),
                          "centro": (x + w // 2, y + h // 2),
                          "conf": int(data["conf"][i])})
        return words


class ScreenReader:
    """
    Une ScreenController (captura) + engine OCR (leitura).
    Métodos usados pelo interpretador para condicionais e cliques em texto.
    """
    def __init__(self, screen, ocr_engine):
        self.screen = screen
        self.ocr = ocr_engine

    def read_screen_text(self) -> str:
        """Texto completo da tela no momento."""
        img = self.screen.capture()
        return self.ocr.read_text(img)

    def text_on_screen(self, texto: str) -> bool:
        """Condicional: o texto aparece na tela?"""
        achado = str(texto).strip().lower()
        return achado in self.read_screen_text().lower()

    def locate_text(self, texto: str):
        """Centro da 1ª ocorrência do texto na tela, ou None."""
        engine = self.ocr
        if not hasattr(engine, "read_words"):
            return None  # engine fake não localiza, só lê
        img = self.screen.capture()
        alvo = str(texto).strip().lower()
        for w in engine.read_words(img):
            if alvo in w["texto"]:
                return w["centro"]
        return None
