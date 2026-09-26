"""
runtime.py - Montagem UNICA da stack de execucao.

Antes (duplicacao): main.py e dashboard/app.py montavam controllers,
guardrails e interpretador separadamente (~40 linhas cada, risco de
divergencia). Agora ambos chamam montar_stack() - uma unica fonte
da verdade para o pipeline de execucao real.
"""

from __future__ import annotations

from types import SimpleNamespace

from agent.config import AgentConfig
from agent.safety.emergency_stop import EmergencyStop
from agent.safety.guardrails import GuardRails
from agent.safety.logger import AuditLogger
from agent.control.mouse import MouseController
from agent.control.keyboard import KeyboardController
from agent.control.screen import ScreenController
from agent.vision.ocr import ScreenReader, TesseractOCREngine
from agent.vision.template_match import TemplateMatcher
from agent.interpreter.interpreter import ScriptInterpreter


def titulo_janela_ativa() -> str:
    """Titulo da janela em foco (pywinauto, import tardio)."""
    try:
        from pywinauto import Desktop
        return Desktop(backend="uia").get_active().window_text()
    except Exception:  # noqa: BLE001 - sem janela ativa = string vazia
        return ""


def montar_stack(
    config: AgentConfig,
    emergencia: EmergencyStop,
    logger: AuditLogger,
    confirmation_fn=None,
    on_event=None,
) -> tuple[ScriptInterpreter, SimpleNamespace]:
    """
    Monta a stack REAL de execucao (Windows).

    Retorna (interpretador, controllers) - o dashboard usa os controllers
    para recursos proprios (ex.: botao de captura imediata).

    confirmation_fn : (action) -> bool - exigida p/ acoes sensiveis em modo real
    on_event        : (fase, acao, verdict) - feed ao vivo do dashboard
    """
    mouse = MouseController()
    keyboard = KeyboardController(
        delay_min_ms=config.typing_delay_min_ms,
        delay_max_ms=config.typing_delay_max_ms)
    screen = ScreenController()
    reader = ScreenReader(screen, TesseractOCREngine())
    matcher = TemplateMatcher(screen)
    analyzer = None
    try:
        from agent.vision.analysis import ScreenAnalyzer
        analyzer = ScreenAnalyzer(screen)
    except Exception:  # noqa: BLE001 - analise cromatica so com cv2/numpy
        analyzer = None

    guardrails = GuardRails(
        config,
        active_window_title_fn=titulo_janela_ativa,
        screen_size_fn=lambda: ScreenController.size())
    guardrails.attach_emergency_stop(emergencia)

    # BUGFIX (26/09/2026): analyzer JAMAIS positional. A assinatura e
    # (..., reader, matcher, confirmation_fn=None, on_event=None,
    #  sleep_fn=time.sleep, analyzer=None) - analyzer como 9o
    # posicion cai na vaga do confirmation_fn, que tambem vem por
    # nome -> TypeError "got multiple values for argument
    # 'confirmation_fn'" ao MONTAR a stack (opcoes [3]/[4]/[6] do
    # menu, main.py e dashboard). Nao tinha teste porque nenhum
    # teste chamava montar_stack; agora existe tests/test_stack.py.
    interpreter = ScriptInterpreter(
        config, guardrails, logger, mouse, keyboard, screen,
        reader, matcher, analyzer=analyzer,
        confirmation_fn=confirmation_fn, on_event=on_event)

    refs = SimpleNamespace(mouse=mouse, keyboard=keyboard, screen=screen,
                           reader=reader, matcher=matcher, analyzer=analyzer)
    return interpreter, refs
