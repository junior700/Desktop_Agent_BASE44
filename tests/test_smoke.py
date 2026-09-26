"""
test_smoke.py - Smoke test: TODOS os .py do projeto devem compilar.

Motivacao (revisao de 25/09/2026): o dashboard/app.py foi entregue com
erro de sintaxe e nenhum teste percebeu, porque a suite nao compilava
os arquivos de UI. Este teste compila CADA .py do projeto, incluindo
dashboard/ e main.py, garantindo que nada quebre por erro de sintaxe.
"""

import os
import py_compile
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _todos_py():
    for dirpath, dirnames, filenames in os.walk(RAIZ):
        dirnames[:] = [d for d in dirnames
                       if d not in ("__pycache__", ".venv", "venv", "env",
                                    "Obsoleto", ".git", "patches")]
        for fn in filenames:
            if fn.endswith(".py"):
                yield os.path.join(dirpath, fn), fn


def run_all():
    results = []
    arquivos = sorted(_todos_py())
    results.append(("projeto tem arquivos python para compilar",
                    len(arquivos) > 0))

    for caminho, nome in arquivos:
        try:
            py_compile.compile(caminho, doraise=True)
            ok = True
        except py_compile.PyCompileError as e:
            print(f"ERRO em {nome}: {e}")
            ok = False
        results.append((f"compila: {nome}", ok))

    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("[OK]" if ok else "[ERRO]"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)
