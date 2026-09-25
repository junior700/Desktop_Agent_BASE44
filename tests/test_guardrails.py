"""
tests/test_guardrails.py — Testes unitários da camada de segurança (Passo 0).
Roda em qualquer SO (não precisa de Windows nem pyautogui): as dependências
de tela/janela são injetadas como funções falsas.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agent.config import AgentConfig
from agent.safety.guardrails import GuardRails
from agent.safety.emergency_stop import EmergencyStop
from agent.safety.logger import AuditLogger


def make_guard(screen=(1920, 1080), window_title="Bloco de notas", **cfg_overrides):
    cfg = AgentConfig(**cfg_overrides)
    return GuardRails(
        cfg,
        active_window_title_fn=lambda: window_title,
        screen_size_fn=lambda: screen,
    )


def run_all():
    results = []

    def check(name, cond):
        results.append((name, bool(cond)))

    # --- 1. Coordenada dentro da tela: permitida ---
    g = make_guard()
    v = g.validate({"tipo": "clicar", "x": 500, "y": 400})
    check("click dentro da tela permitido", v.allowed)

    # --- 2. Coordenada fora da tela: bloqueada ---
    for bad in ({"x": 2000, "y": 400}, {"x": -1, "y": 100}, {"x": 500, "y": 1080}):
        v = g.validate({"tipo": "clicar", **bad})
        check(f"click fora da tela bloqueado {bad}", not v.allowed)

    # --- 3. Click sem coordenada: bloqueado ---
    v = g.validate({"tipo": "clicar"})
    check("click sem coordenada bloqueado", not v.allowed)

    # --- 4. Janela blacklist: bloqueada ---
    g = make_guard(window_title="Gerenciador de Tarefas")
    check("task manager bloqueado", not g.validate({"tipo": "clicar", "x": 10, "y": 10}).allowed)
    g = make_guard(window_title="Prompt de Comando")
    check("cmd bloqueado", not g.validate({"tipo": "digitar", "texto": "echo oi"}).allowed)

    # --- 5. Combo proibido direto e normalizado ---
    g = make_guard()
    check("ctrl+shift+esc bloqueado", not g.validate({"tipo": "tecla", "combinacao": "ctrl+shift+esc"}).allowed)
    check("variante esc+shift+ctrl bloqueada",
          not g.validate({"tipo": "tecla", "combinacao": "esc+shift+ctrl"}).allowed)

    # --- 6. Texto destrutivo: bloqueado (início de palavra, não dentro) ---
    check("del bloqueado", not g.validate({"tipo": "digitar", "texto": "del arquivo.txt"}).allowed)
    check("format bloqueado", not g.validate({"tipo": "digitar", "texto": "format c:"}).allowed)
    check("palavra com 'del' dentro ok", g.validate({"tipo": "digitar", "texto": "modelo deled isValid"}).allowed)
    check("texto normal ok", g.validate({"tipo": "digitar", "texto": "Ola, mundo!"}).allowed)

    # --- 7. Ações sensíveis: permitidas, mas pedem confirmação ---
    g = make_guard()
    v = g.validate({"tipo": "apagar_arquivo", "caminho": "C:/temp/x.txt"})
    check("acao sensivel exige confirmacao", v.allowed and v.requires_confirmation)

    # --- 8. Tipo desconhecido: recusado (fail-safe) ---
    check("tipo desconhecido bloqueado", not g.validate({"tipo": "formatar_disco"}).allowed)

    # --- 9. Rate limit ---
    g = make_guard(max_actions_per_minute=5)
    ok = all(g.validate({"tipo": "aguardar", "segundos": 1}).allowed for _ in range(5))
    check("5 primeiras acoes ok", ok)
    check("6a acao bloqueada (rate limit)", not g.validate({"tipo": "aguardar", "segundos": 1}).allowed)

    # --- 10. Emergência ESC 3x bloqueia tudo ---
    g = make_guard()
    em = EmergencyStop(presses_required=3, window_s=1.5, test_mode=True)
    g.attach_emergency_stop(em)
    for _ in range(3):
        em.register_press()
    check("esc 3x dispara", em.is_triggered())
    check("tudo bloqueado apos esc 3x", not g.validate({"tipo": "aguardar", "segundos": 1}).allowed)
    em.reset()
    check("reset libera novamente", g.validate({"tipo": "aguardar", "segundos": 1}).allowed)

    # --- 11. ESC espaçado não dispara ---
    em2 = EmergencyStop(presses_required=3, window_s=0.05, test_mode=True)
    import time as _t
    em2.register_press()
    _t.sleep(0.08)
    em2.register_press()
    check("esc lento nao dispara", not em2.is_triggered())

    # --- 12. Logger de auditoria ---
    with tempfile.TemporaryDirectory() as tmp:
        log = AuditLogger(os.path.join(tmp, "test.db"))
        g2 = make_guard()
        g2.validate({"tipo": "clicar", "x": 500, "y": 400})  # permitida
        g2.validate({"tipo": "clicar", "x": 99999, "y": 0})  # bloqueada
        log.log("clicar", {"x": 500, "y": 400}, True, True, "ok", True)
        log.log("clicar", {"x": 99999, "y": 0}, False, False, "fora da tela", True)
        s = log.stats()
        check("logger registra 2 eventos", s["total"] == 2)
        check("logger conta 1 bloqueio", s["blocked"] == 1)
        check("logger recent() retorna eventos", len(log.recent(10)) == 2)
        log.close()

    # --- 13. Config inválida levanta erro na inicialização ---
    try:
        AgentConfig(max_actions_per_minute=0).validate()
        check("config invalida rejeitada", False)
    except ValueError:
        check("config invalida rejeitada", True)

    return results


if __name__ == "__main__":
    results = run_all()
    passed = sum(1 for _, ok in results if ok)
    for name, ok in results:
        print(("✅" if ok else "❌"), name)
    print(f"\n{passed}/{len(results)} testes passaram")
    sys.exit(0 if passed == len(results) else 1)
