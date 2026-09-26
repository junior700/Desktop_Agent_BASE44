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
from agent.runtime import montar_stack


def confirmar_terminal(ac):
    """Confirmação de ação sensível no CLI (s/N)."""
    print(f"\n*** ACAO SENSIVEL: {ac.get('tipo')} ***")
    print(f"    {ac}")
    resp = input("    Aprovar? [s/N] ").strip().lower()
    return resp == "s"


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
    print("  F12  -> INICIA a gravacao (esta janela MINIMIZA sozinha)")
    print("  F10  -> ENCERRA e salva (a janela VOLTAR a tela sozinha)")
    print("  ESC 3x = emergencia global (encerra e restaura a janela)")
    if not rec.arm():
        print("ERRO: pynput indisponivel.")
        sys.exit(1)
    import time as _time
    try:
        while not rec.is_stopped and not emergencia.triggered:
            _time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    rec.stop()  # sempre restaura a janela ao encerrar
    if rec.save_script(saida) is None:
        print("0 cliques gravados — roteiro vazio NAO foi salvo.")
    else:
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
    interpreter, _refs = montar_stack(config, emergencia, logger,
                                      confirmation_fn=confirmar_terminal)

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
