"""
native_dialogs.py — Seletores NATIVOS do Windows (arquivo/pasta).

Toda escolha de arquivo ou pasta do projeto abre a janela nativa do
Windows (File Explorer), JÁ APONTADA para a pasta correta do caso:

    roteiros (abrir)      -> scripts\
    roteiros (gravar)     -> scripts\
    templates de imagem   -> templates\
    pasta de capturas     -> capturas\

No Windows, os diálogos do Tkinter renderizam a janela nativa do
sistema (comdlg32), então o usuário vê o File Explorer padrão.
"""

from __future__ import annotations

import os
from tkinter import filedialog

# agent/ui/native_dialogs.py -> raiz do projeto (3 níveis acima)
_PROJECT_ROOT = os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))))


def pasta_do_projeto(nome: str) -> str:
    """Caminho absoluto de uma subpasta do projeto (criando se não existir)."""
    p = os.path.join(_PROJECT_ROOT, nome)
    os.makedirs(p, exist_ok=True)
    return p


FILTRO_JSON = [("Roteiros JSON", "*.json"), ("Todos os arquivos", "*.*")]
FILTRO_IMAGEM = [("Imagens", "*.png;*.jpg;*.jpeg;*.bmp"), ("Todos", "*.*")]


def selecionar_arquivo(pasta: str = "scripts", salvar: bool = False,
                      nome_default: str = "roteiro.json",
                      filtros=FILTRO_JSON) -> str:
    """
    Janela nativa de escolha de ARQUIVO, já na pasta correta.
    Retorna o caminho escolhido ou "" se o usuário cancelar.
    """
    inicial = pasta_do_projeto(pasta)
    if salvar:
        return filedialog.asksaveasfilename(
            initialdir=inicial, initialfile=nome_default,
            filetypes=filtros, defaultextension=".json")
    return filedialog.askopenfilename(
        initialdir=inicial, filetypes=filtros)


def selecionar_pasta(pasta: str = "capturas") -> str:
    """
    Janela nativa de escolha de PASTA, já na pasta correta do caso.
    Retorna o caminho escolhido ou "" se o usuário cancelar.
    """
    inicial = pasta_do_projeto(pasta)
    return filedialog.askdirectory(initialdir=inicial)
