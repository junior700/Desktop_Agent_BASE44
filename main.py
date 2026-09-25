"""
main.py — CLI do agente de desktop.

Uso:
    python main.py roteiro.json            # dry-run (simula, não toca em nada)
    python main.py roteiro.json --real    # execução REAL (mouse/teclado)
    python main.py --gravar saida.json    # Human Recorder (F12 encerra)
    python main.py --dashboard            # abre o painel Tkinter

--real exige confirmação no terminal antes de começar.
ESC 3x interrompe tudo a qualquer momento.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

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


def construir_stack(config: AgentConfig, emergencia: EmergencyStop,
                    logger: AuditLogger):
    """Monta interpretador com controllers reais (Windows)."""
    mouse = MouseController()
    keyboard = KeyboardController(
        delay_min_ms=config.typing_delay_min_ms,
        delay_max_ms=config.typing_delay_max_ms)
    screen = ScreenController()
    reader = ScreenReader(screen, TesseractOCREngine())
    matcher = TemplateMatcher(screen)
    guardrails = GuardRails(
        config,
        active_window_title_fn=_titulo_janela_ativa,
        screen_size_fn=lambda: ScreenController.size())
    guardrails.attach_emergency_stop(emergencia)

    def confirmar_terminal(ac):
        print(f"\n*** ACAO SENSIVEL: {ac.get('tipo')} ***")
        print(f"    {ac}")
        resp = input("    Aprovar? [s/N] ").strip().lower()
        return resp == "s"

    return ScriptInterpreter(config, guardrails, logger,
                             mouse, keyboard, screen, reader, matcher,
                             confirmation_fn=confirmar_terminal)


def _titulo_janela_ativa() -> str:
    try:
        from pywinauto import Desktop
        return Desktop(backend="uia").get_active().window_text()
    except Exception:  # noqa: BLE001
        return ""


def cmd_gravar(saida: str | None) -> None:
    if not saida:
        # Sem arquivo definido: janela nativa de SALVAR, aberta em scripts\.
        from agent.ui.native_dialogs import selecionar_arquivo
        saida = selecionar_arquivo(pasta="scripts", salvar=True,
                                   nome_default="gravacao.json")
        if not saida:
            sys.exit(2)
    from agent.recorder.recorder import HumanRecorder
    config = AgentConfig()
    config.validate()
    emergencia = EmergencyStop(
        presses_required=config.emergency_esc_presses,
        window_s=config.emergency_window_s)
    emergencia.start()
    rec = HumanRecorder(config, emergency=emergencia)
    print("Recorder armado.")
    print("  F12  -> INICIA a gravacao de cliques")
    print("  F10  -> ENCERRA e salva o roteiro")
    print("  ESC 3x = emergencia global")
    if not rec.arm():
        print("ERRO: pynput indisponivel.")
        sys.exit(1)
    import time as _time
    try:
        while not rec.is_stopped:
            _time.sleep(0.1)
    except KeyboardInterrupt:
        rec.stop()
    rec.save_script(saida)
    print(f"Roteiro salvo em: {saida} ({rec.click_count()} cliques)")


def main():
    ap = argparse.ArgumentParser(description="Agente de desktop")
    ap.add_argument("roteiro", nargs="?", help="arquivo de roteiro JSON")
    ap.add_argument("--real", action="store_true",
                    help="execucao REAL (default: dry-run)")
    ap.add_argument("--gravar", metavar="SAIDA", nargs="?", const="",
                    help="gravar cliques: F12 inicia, F10 encerra (sem caminho = janela nativa)")
    ap.add_argument("--dashboard", action="store_true",
                    help="abrir painel Tkinter")
    args = ap.parse_args()

    if args.dashboard:
        os.system("")  # ativa cores ANSI no terminal do Windows (noop real)
        from dashboard.app import main as dash_main
        dash_main()
        return

    if args.gravar:
        cmd_gravar(args.gravar)
        return

    if not args.roteiro:
        # Sem caminho na linha de comando: abre a janela NATIVA do Windows,
        # já apontada para a pasta scripts\ do projeto.
        from agent.ui.native_dialogs import selecionar_arquivo
        escolhido = selecionar_arquivo(pasta="scripts")
        if not escolhido:
            ap.print_help()
            sys.exit(2)
        args.roteiro = escolhido
    if not os.path.isfile(args.roteiro):
        print(f"ERRO: roteiro nao encontrado: {args.roteiro}")
        sys.exit(1)

    config = AgentConfig()
    config.validate()
    config.dry_run = not args.real

    emergencia = EmergencyStop(
        presses_required=config.emergency_esc_presses,
        window_s=config.emergency_window_s)
    emergencia.start()

    logger = AuditLogger(config.audit_db_path)
    interpreter = construir_stack(config, emergencia, logger)

    if args.real:
        print("*** MODO REAL: o agente vai controlar mouse e teclado. ***")
        print("*** ESC 3x interrompe imediatamente. ***")
        resp = input("Continuar? [s/N] ").strip().lower()
        if resp != "s":
            print("Abortado pelo operador.")
            sys.exit(0)

    try:
        res = interpreter.run_file(args.roteiro)
        print(f"CONCLUIDO ok={res.ok} executadas={res.executadas} "
              f"bloqueadas={res.bloqueadas}")
        if res.abort_reason:
            print(f"motivo do aborto: {res.abort_reason}")
        sys.exit(0 if res.ok else 1)
    finally:
        emergencia.stop()
        logger.close()


if __name__ == "__main__":
    main()
