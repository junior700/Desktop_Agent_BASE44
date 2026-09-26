"""
test_stack.py - Testes do montar_stack (agent/runtime.py).

Motivacao (bug real 26/09/2026): as opcoes [3]/[4]/[6] do menu
quebravam com TypeError "got multiple values for argument
'confirmation_fn'" porque o montar_stack passava o analyzer como
9o argumento POSICIONAL, que cai na vaga do confirmation_fn
(tambem passado por nome). Nenhum teste chamava montar_stack, e o
smoke (py_compile) nao pega TypeError de chamada - so erro de
sintaxe. Este modulo monta a stack REAL (construtores de verdade,
sem tocar hardware: init nao clica nem digita nada) e valida a
ligacao dos fios que main.py e dashboard dependem.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agent.config import AgentConfig
from agent.safety.emergency_stop import EmergencyStop
from agent.safety.logger import AuditLogger
from agent.runtime import montar_stack


def _montar():
    """Monta a stack em dry_run com sentinelas nos callbacks."""
    cfg = AgentConfig(dry_run=True)
    emerg = EmergencyStop()
    logger = AuditLogger(":memory:")

    def confirmation_fn(ac):
        return False

    def on_event(fase, ac, verdict):
        pass

    itp, refs = montar_stack(cfg, emerg, logger,
                             confirmation_fn=confirmation_fn,
                             on_event=on_event)
    return itp, refs


def run_all():
    """Roda todas as validacoes; retorna [(nome, ok), ...]."""
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # --- a stack inteira monta (o bug real estourava AQUI) ---
    try:
        itp, refs = _montar()
        check("montar_stack monta sem TypeError", True)
    except TypeError as e:
        check(f"montar_stack monta sem TypeError ({e})", False)
        return results

    # --- refs: os 6 controllers que o dashboard usa ---
    for nome in ("mouse", "keyboard", "screen",
                 "reader", "matcher", "analyzer"):
        check(f"refs expoe o controller {nome}",
              hasattr(refs, nome))

    # --- fios que o bug real cruzava ---
    check("confirmation_fn ligada (nao engolida pelo analyzer)",
          itp.confirmation_fn is not None)
    check("confirmation_fn e callable (e um callback de verdade)",
          callable(itp.confirmation_fn))
    check("confirmation_fn responde False (sentinela)",
          itp.confirmation_fn({"acao": "teste"}) is False)
    check("on_event ligado (nao engolido pelo analyzer)",
          itp.on_event is not None)
    check("on_event e callable (e um callback de verdade)",
          callable(itp.on_event))
    check("guardrails anexados ao interpretador",
          itp.guardrails is not None)
    check("logger anexado ao interpretador",
          itp.logger is not None)

    return results


if __name__ == "__main__":
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)
