"""
run_all.py - Roda TODOS os testes do projeto e reporta o total.
Uso: python tests/run_all.py  (no Windows: .venv\\Scripts\\python tests\\run_all.py)
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTES = [
    "test_guardrails.py",
    "test_control.py",
    "test_interpreter.py",
    "test_recorder.py",
    "test_decision.py",
    "test_smoke.py",
    "test_vision.py",
    "test_sed_gerar_exe.py",
]


def main():
    total_ok = total = 0
    falhou = []
    for t in TESTES:
        path = os.path.join(HERE, t)
        print(f"\n{'='*60}\n>>> {t}\n{'='*60}")
        r = subprocess.run([sys.executable, path])
        out = _contar(path)
        total_ok += out[0]
        total += out[1]
        if r.returncode != 0 or out[0] != out[1]:
            falhou.append(t)

    print(f"\n{'='*60}")
    print(f"TOTAL GERAL: {total_ok}/{total} testes passaram")
    if falhou:
        print(f"FALHARAM: {', '.join(falhou)}")
        sys.exit(1)
    print("TODOS OS MODULOS OK")
    sys.exit(0)


def _contar(path):
    """Importa o modulo de teste e roda run_all() para contar as checagens."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(path, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    rs = mod.run_all()
    return sum(1 for _, ok in rs if ok), len(rs)


if __name__ == "__main__":
    main()
