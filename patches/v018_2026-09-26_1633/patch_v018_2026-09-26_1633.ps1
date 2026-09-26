# ============================================================
# patch.ps1 - aplicador automatico de correcoes
#
# COMO USAR (na raiz do projeto):
#   - opcao [9] do menu agente.ps1, ou
#   - powershell -ExecutionPolicy Bypass -File .\patch.ps1
#
# O QUE ELE FAZ (nesta ordem):
#   1. cria a pasta patches\ (se nao existir)
#   2. calcula a proxima versao: patches\vNNN_AAAA-MM-DD_HHMM\
#   3. backup dos arquivos ATUAIS em <ver>\anteriores\
#   4. grava os arquivos corrigidos nos lugares devidos
#      (cria subpastas se faltar; inclusao = arquivo novo)
#   5. guarda copia versionada dos novos em <ver>\
#   6. guarda copia versionada DE SI MESMO em <ver>\
#   7. anexa uma linha no patches\registro.csv
#   8. mostra o resumo, espera ENTER e SE AUTODESTRUI
#
# RASTREIO: patches\registro.csv guarda versao, data, arquivos
# e resultado. Rollback manual: copie de <ver>\anteriores\.
#
# REGRAS DO PROJETO: ASCII puro, pausa antes de qualquer saida,
# confirmacao antes de tocar em qualquer arquivo.
# ============================================================

$ErrorActionPreference = "Stop"
$Raiz = $PSScriptRoot
if (-not $Raiz) { $Raiz = (Get-Location).Path }

Write-Host ""
Write-Host "=== PATCH AUTOMATICO - Desktop_Agent ===" -ForegroundColor Cyan
Write-Host "Raiz do projeto: $Raiz"
Write-Host ""

# --- arquivos embutidos: destino relativo -> conteudo ---
$Arquivos = @{

    "agent\recorder\recorder.py" = @'
"""
recorder.py - Human Recorder.

Grava acoes humanas e gera um ROTEIRO JSON no mesmo schema do interpretador.

DIRETRIZ DO PROJETO: grava apenas CLIQUES (coordenada + botao) e o
INTERVALO DE TEMPO entre cliques. Movimento do mouse entre cliques
e teclas digitadas NAO sao gravados.

Saida:
    {"nome": "...", "acoes": [
        {"tipo": "clicar", "x": 100, "y": 200, "botao": "left"},
        {"tipo": "aguardar", "segundos": 1.42},
        {"tipo": "duplo_clique", "x": 300, "y": 250},
        ...
    ]}

Duplo clique: 2 cliques no mesmo ponto (tolerancia 4px) em menos de
double_click_window_ms, botao esquerdo.

TECLAS (conforme diretriz do usuario):
    F12 -> INICIA a gravacao de cliques (e MINIMIZA esta janela)
    F10 -> ENCERRA a gravacao e finaliza (e RESTAURA esta janela)

Fluxo: arm() instala os listeners (estado "armado"); F12 liga a captura;
F10 desliga e encerra. ESC 3x dispara a emergencia global a qualquer momento.
"""

from __future__ import annotations

import json
import time

from agent.config import AgentConfig


# ------------------------------------------------------------------
# Controle da janela do console (Windows).
# F12 -> minimizar a janela do script (nao atrapalha a gravacao)
# F10 -> restaurar a janela no fim
# ------------------------------------------------------------------
SW_MINIMIZE = 6
SW_RESTORE = 9


def minimize_console() -> None:
    """Minimiza a janela do console atual (nao faz nada fora do Windows)."""
    try:
        import ctypes
        hwnd = ctypes.windll.kernel32.GetConsoleWindow()
        if hwnd:
            ctypes.windll.user32.ShowWindow(hwnd, SW_MINIMIZE)
    except Exception:
        pass


# Flags do console do Windows (Win32): modo de edicao rapida.
ENABLE_QUICK_EDIT = 0x0040
ENABLE_INSERT_MODE = 0x0020
ENABLE_EXTENDED_FLAGS = 0x0080


def disable_quickedit() -> bool:
    """Desativa o QuickEdit do console. Retorna True se aplicou.

    BUG REAL (26/09/2026, modo REAL): um unico clique do usuario na
    area do console ativa o modo SELECAO do QuickEdit e congela a
    proxima escrita de stdout - o processo INTEIRO aparenta travar
    (o ESC 3x dispara a flag, mas o main thread esta preso no print;
    so solta quando a janela do console recebe uma tecla). Desativar
    ENABLE_QUICK_EDIT_MODE elimina o congelamento por clique. Fora
    do Windows ou sem console retorna False (no-op seguro).
    """
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        if not kernel32.GetConsoleWindow():
            return False
        # STD_INPUT_HANDLE = -10
        hinput = kernel32.GetStdHandle(-10)
        modo = ctypes.c_uint()
        if not kernel32.GetConsoleMode(hinput, ctypes.byref(modo)):
            return False
        novo = ((modo.value & ~ENABLE_QUICK_EDIT &
                 ~ENABLE_INSERT_MODE) | ENABLE_EXTENDED_FLAGS)
        return bool(kernel32.SetConsoleMode(hinput, novo))
    except Exception:  # noqa: BLE001 - no-op fora do Windows
        return False


def restore_console() -> None:
    """Restaura a janela do console atual (nao faz nada fora do Windows)."""
    try:
        import ctypes
        hwnd = ctypes.windll.kernel32.GetConsoleWindow()
        if hwnd:
            ctypes.windll.user32.ShowWindow(hwnd, SW_RESTORE)
    except Exception:
        pass


class HumanRecorder:
    def __init__(self, config: AgentConfig, emergency=None,
                 clock=time.monotonic, window_ctl=None):
        self.config = config
        self.emergency = emergency      # EmergencyStop compartilhado
        # controlador de janela: minimiza no F12, restaura no F10
        if window_ctl is None:
            window_ctl = type("ConsoleWindowCtl", (), {
                "minimize": staticmethod(minimize_console),
                "restore": staticmethod(restore_console),
            })()
        self.window_ctl = window_ctl
        self._clock = clock            # injetavel p/ testes
        self._events: list[dict] = []  # [{"t": s, "x": int, "y": int, "botao": str}]
        self._listener = None
        self._kb_listener = None
        self._recording = False   # capturando cliques agora
        self._armed = False       # listeners instalados, aguardando F12
        self._stopped = False    # F10 apertado (ou stop manual): fim

    # ------------------------------------------------------------------
    # API de teste: injeta um clique como se viesse do mouse real.
    # ------------------------------------------------------------------
    def record_click(self, x: int, y: int, botao: str = "left",
                     t: float | None = None) -> None:
        self._events.append({"t": self._clock() if t is None else t,
                             "x": int(x), "y": int(y), "botao": botao})

    # ------------------------------------------------------------------
    # Gravacao real (Windows) - pynput.
    # ------------------------------------------------------------------
    def arm(self) -> bool:
        """
        Instala os listeners e fica ARMADO: aguardando F12 para comecar
        a capturar cliques e F10 para encerrar. Retorna True se armado.
        """
        if self._armed and not self._stopped:
            return True
        try:
            from pynput import mouse, keyboard  # import tardio
        except ImportError:
            return False

        self._armed = True
        self._stopped = False
        self._recording = False

        start_key = self.config.recorder_start_key  # F12
        stop_key = self.config.recorder_stop_key     # F10

        def on_click(x, y, button, pressed):
            if not self._recording or not pressed:
                return  # so captura enquanto grava; so o pressionar conta
            botao = "right" if "right" in str(button) else \
                    "middle" if "middle" in str(button) else "left"
            self.record_click(x, y, botao)

        def on_press(key):
            nome = getattr(key, "name", "")
            if nome == start_key and not self._recording:
                self._events.clear()
                self._recording = True
                # minimiza a janela do script: nao atrapalha a gravacao
                self.window_ctl.minimize()
            elif nome == stop_key:
                self._recording = False
                self.stop()  # desliga listeners; _stopped sinaliza o fim
            elif nome == "escape" and self.emergency:
                self.emergency.register_press()  # ESC 3x tambem vale aqui

        self._listener = mouse.Listener(on_click=on_click)
        self._listener.daemon = True
        self._listener.start()

        self._kb_listener = keyboard.Listener(on_press=on_press)
        self._kb_listener.daemon = True
        self._kb_listener.start()
        return True

    def start(self) -> bool:
        """Arma E comeca a gravar imediatamente (sem aguardar F12)."""
        if not self.arm():
            return False
        self._events.clear()
        self._recording = True
        return True

    def stop(self) -> None:
        self._recording = False
        self._stopped = True
        # fim da gravacao: devolve a janela do script a tela
        try:
            self.window_ctl.restore()
        except Exception:
            pass
        if self._listener is not None:
            self._listener.stop()
            self._listener = None
        if self._kb_listener is not None:
            self._kb_listener.stop()
            self._kb_listener = None

    @property
    def is_armed(self) -> bool:
        return self._armed and not self._stopped

    @property
    def is_stopped(self) -> bool:
        return self._stopped

    @property
    def is_recording(self) -> bool:
        return self._recording

    def click_count(self) -> int:
        return len(self._events)

    # ------------------------------------------------------------------
    # Conversao eventos -> roteiro JSON
    # ------------------------------------------------------------------
    def build_script(self, nome: str = "gravacao") -> dict:
        """
        Gera o roteiro:
        - cada clique vira 'clicar'/'clique_direito'/'duplo_clique'
        - o intervalo real entre acoes vira 'aguardar' (2 casas decimais)
        """
        eventos = sorted(self._events, key=lambda e: e["t"])
        janela = self.config.double_click_window_ms / 1000.0

        # 1? passada: agrupa duplos cliques.
        # Cada entrada: (idx_inicio, idx_fim_exclusivo, acao)
        passos: list[tuple[int, int, dict]] = []
        i = 0
        while i < len(eventos):
            ev = eventos[i]
            nxt = eventos[i + 1] if i + 1 < len(eventos) else None
            if (nxt is not None
                    and ev["botao"] == nxt["botao"] == "left"
                    and nxt["t"] - ev["t"] <= janela
                    and abs(nxt["x"] - ev["x"]) <= 4
                    and abs(nxt["y"] - ev["y"]) <= 4):
                passos.append((i, i + 2,
                               {"tipo": "duplo_clique", "x": ev["x"], "y": ev["y"]}))
                i += 2
            else:
                tipo = "clique_direito" if ev["botao"] == "right" else "clicar"
                passos.append((i, i + 1,
                               {"tipo": tipo, "x": ev["x"], "y": ev["y"],
                                "botao": ev["botao"]}))
                i += 1

        # 2? passada: insere 'aguardar' entre passos consecutivos.
        acoes: list[dict] = []
        for pos, (ini, fim, acao) in enumerate(passos):
            if pos > 0:
                delta = eventos[ini]["t"] - eventos[passos[pos - 1][1] - 1]["t"]
                acoes.append({"tipo": "aguardar", "segundos": round(max(delta, 0), 2)})
            acoes.append(acao)

        return {"nome": nome, "acoes": acoes}

    def save_script(self, path: str, nome: str = "gravacao") -> str | None:
        """
        Salva o roteiro. Retorna o caminho, ou None se NADA foi gravado
        (0 cliques: um roteiro vazio e invalido para o interpretador -
        nao criar arquivo inutil e mais honesto que criar um que falha).
        """
        script = self.build_script(nome)
        if not script["acoes"]:
            return None
        with open(path, "w", encoding="utf-8") as f:
            json.dump(script, f, ensure_ascii=False, indent=2)
        return path

'@
    "agent\control\mouse.py" = @'
"""
mouse.py - Controle de mouse (cliques e posicionamento).

DIRETRIZ DO PROJETO: a trajetoria do mouse nao importa.
Movimento entre cliques = teleporte direto (moveTo).
O que importa: coordenada do clique, botao, e intervalo entre cliques.

O backend real e o pyautogui (import tardio - so quando o agente roda
de verdade no Windows). O FAILSAFE do pyautogui fica LIGADO: levar o mouse
ao canto superior esquerdo da tela tambem interrompe o pyautogui.
"""

from __future__ import annotations

from typing import Optional


class MouseController:
    def __init__(self, backend=None):
        """backend: objeto com moveTo/click/position (pyautogui ou fake p/ testes)."""
        self._backend = backend

    @property
    def backend(self):
        if self._backend is None:
            import pyautogui  # import tardio: so no Windows/runtime real
            pyautogui.FAILSAFE = True  # canto da tela = aborto extra (mantem)
            pyautogui.PAUSE = 0.1
            self._backend = pyautogui
        return self._backend

    # ------------------------------------------------------------------
    def move(self, x: int, y: int) -> None:
        """Teleporta o mouse para (x, y). Sem trajetoria, sem suavizacao."""
        self.backend.moveTo(int(x), int(y))

    def click(self, x: Optional[int] = None, y: Optional[int] = None,
              button: str = "left", clicks: int = 1,
              interval_s: float = 0.0) -> None:
        """Clica. Se der coordenada, teleporta antes (1 movimento, 0 fisica)."""
        if x is not None and y is not None:
            self.move(x, y)
        if interval_s > 0:
            import time
            time.sleep(interval_s)
        self.backend.click(clicks=clicks, button=button, interval=0.05)

    def double_click(self, x: Optional[int] = None, y: Optional[int] = None) -> None:
        self.click(x, y, button="left", clicks=2, interval_s=0.05)

    def right_click(self, x: Optional[int] = None, y: Optional[int] = None,
                    settle_s: float = 0.05, hold_s: float = 0.05) -> None:
        """Clique direito com settle apos o teleporte e hold real.

        BUG REAL (26/09/2026): o replay usava click(button='right')
        imediatamente apos o moveTo - down+up na MESMA batelada logo
        apos SetCursorPos. Menu de contexto do Windows dispara no
        mouse UP (WM_CONTEXTMENU); pressao de zero ms pode ser
        ignorada pelo app alvo (clique gravado nao abriu o menu na
        reproducao). 50ms de settle (posicao assentar antes de
        pressionar) + 50ms de hold (pressao de verdade antes de
        soltar) = janela humana confiavel. Ainda teleporte, sem
        trajetoria. Parametros injetaveis p/ testes instantaneos.
        """
        if x is not None and y is not None:
            self.move(x, y)
        import time
        if settle_s > 0:
            time.sleep(settle_s)
        self.backend.mouseDown(button="right")
        if hold_s > 0:
            time.sleep(hold_s)
        self.backend.mouseUp(button="right")

    def position(self) -> tuple[int, int]:
        """Posicao atual do cursor (usado pelo dashboard/recorder)."""
        return tuple(self.backend.position())

'@
    "main.py" = @'
"""
main.py - CLI do agente de desktop.

Uso:
    python main.py roteiro.json            # dry-run (simula, nao toca em nada)
    python main.py roteiro.json --real    # execucao REAL (mouse/teclado)
    python main.py --gravar saida.json    # Human Recorder (F12 encerra)
    python main.py --dashboard            # abre o painel Tkinter

--real exige confirmacao no terminal antes de comecar.
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
from agent.recorder.recorder import minimize_console, restore_console
from agent.recorder.recorder import disable_quickedit


def confirmar_terminal(ac):
    """Confirmacao de acao sensivel no CLI (s/N)."""
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
        while not rec.is_stopped and not emergencia.is_triggered():
            _time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    rec.stop()  # sempre restaura a janela ao encerrar
    if rec.save_script(saida) is None:
        print("0 cliques gravados - roteiro vazio NAO foi salvo.")
    else:
        print(f"Roteiro salvo em: {saida} ({rec.click_count()} cliques)")


def main():
    # QuickEdit OFF: um clique do usuario no console NAO pode congelar
    # o processo no meio da execucao (bug real 26/09/2026).
    disable_quickedit()
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
        # ja apontada para a pasta scripts\ do projeto.
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
    if not emergencia.start():
        print("AVISO: listener do ESC 3x indisponivel (pynput ausente).")
        print("       Aborto alternativo: leve o mouse ao canto sup. esquerdo.")

    logger = AuditLogger(config.audit_db_path)
    interpreter, _refs = montar_stack(config, emergencia, logger,
                                      confirmation_fn=confirmar_terminal)

    if args.real:
        print("*** MODO REAL: o agente vai controlar mouse e teclado. ***")
        print("*** ESC 3x interrompe imediatamente. ***")
        print("*** Aborto alternativo: mouse no canto sup. esquerdo. ***")
        resp = input("Continuar? [s/N] ").strip().lower()
        if resp != "s":
            print("Abortado pelo operador.")
            sys.exit(0)
        # A janela deste script MINIMIZA durante a execucao (mesmo
        # comportamento do Human Recorder no F12) para nao atrapalhar
        # os cliques; volta ao final para mostrar o resultado. ESC 3x
        # continua funcionando (listener global do pynput).
        print("Minimizando esta janela durante a execucao...")
        minimize_console()

    try:
        res = interpreter.run_file(args.roteiro)
        if args.real:
            restore_console()
        print(f"CONCLUIDO ok={res.ok} executadas={res.executadas} "
              f"bloqueadas={res.bloqueadas}")
        if res.abort_reason:
            print(f"motivo do aborto: {res.abort_reason}")
        sys.exit(0 if res.ok else 1)
    finally:
        if args.real:
            restore_console()
        emergencia.stop()
        logger.close()


if __name__ == "__main__":
    main()

'@
    "dashboard\app.py" = @'
"""
app.py - Dashboard Tkinter do agente de desktop.

Funcionalidades:
- Carregar roteiro via seletor de arquivos (File Explorer)
- Executar roteiro com modo dry-run (default LIGADO) ou real
- Feed ao vivo das acoes (executada/bloqueada/dry_run)
- Estatisticas do audit log (total/permitidas/bloqueadas/executadas)
- Confirmacao de acoes sensiveis (janela modal)
- Botao de PARADA DE EMERGENCIA e reset (ESC 3x tambem funciona)

O roteiro roda numa THREAD separada; a UI nunca trava.
Eventos chegam a UI via fila (thread-safe).
"""

from __future__ import annotations

import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from agent.config import AgentConfig
from agent.safety.emergency_stop import EmergencyStop
from agent.safety.logger import AuditLogger
from agent.runtime import montar_stack
from agent.ui.native_dialogs import selecionar_arquivo, selecionar_pasta
# minimize/restore da janela do console - mesmo mecanismo do Human
# Recorder (ctypes GetConsoleWindow + ShowWindow), reaproveitado aqui
# para nao duplicar codigo Win32 (DRY).
from agent.recorder.recorder import minimize_console, restore_console
from agent.recorder.recorder import disable_quickedit


class Dashboard:
    def __init__(self, root: tk.Tk, window_ctl=None):
        self.root = root
        root.title("Desktop Agent - Painel de Controle")
        root.geometry("900x580")
        root.minsize(760, 480)

        # controlador da janela do console: minimiza agora que o
        # dashboard esta ativo, restaura quando o usuario fechar
        # (injetavel para testes - mesmo padrao do HumanRecorder)
        if window_ctl is None:
            window_ctl = type("ConsoleWindowCtl", (), {
                "minimize": staticmethod(minimize_console),
                "quickedit_off": staticmethod(disable_quickedit),
                "restore": staticmethod(restore_console),
            })()
        self.window_ctl = window_ctl
        # QuickEdit OFF antes de minimizar: clique do usuario na janela
        # do console nao pode congelar nada (mesma protecao do CLI).
        self.window_ctl.quickedit_off()
        self.window_ctl.minimize()
        root.protocol("WM_DELETE_WINDOW", self._ao_fechar)

        self.config = AgentConfig()
        self.config.validate()
        self.emergency = EmergencyStop(
            presses_required=self.config.emergency_esc_presses,
            window_s=self.config.emergency_window_s)
        self.emergency.start()
        self.logger = AuditLogger(self.config.audit_db_path)

        # Stack UNICA compartilhada com o CLI (agent/runtime.py)
        self.interpreter, self.refs = montar_stack(
            self.config, self.emergency, self.logger,
            confirmation_fn=self._confirmar_sensivel,
            on_event=lambda fase, ac, v: self.events.put((fase, ac, v.reason)))

        self.events: "queue.Queue[tuple]" = queue.Queue()
        self.script_path: str | None = None
        self.runner_thread: threading.Thread | None = None

        self._build_ui()
        self.root.after(200, self._drain_events)

    # ------------------------------------------------------------------
    def _ao_fechar(self):
        """Restaura a janela do console (minimizada ao abrir) e fecha."""
        self.window_ctl.restore()
        self.root.destroy()

    # ------------------------------------------------------------------
    def _build_ui(self):
        """Botoes agrupados por proposito (ttk.LabelFrame).

        Bug real corrigido (26/09/2026, screenshot do usuario): o
        botao 'Capturar tela agora' e o rotulo lbl_capdir ocupavam a
        MESMA celula do grid (row=0, column=2 em topo2) - colisao
        real do Tkinter, as duas legendas ficavam desenhadas uma
        sobre a outra (o texto 'embaralhado' na tela). Agrupar em
        LabelFrame tambem elimina o excesso de texto repetido em
        cada botao (ex.: '(emergencia)' 2x) - o titulo do grupo ja
        da o contexto.
        """
        pad = {"padx": 6, "pady": 4}

        grp_roteiro = ttk.LabelFrame(self.root, text="Roteiro")
        grp_roteiro.pack(fill="x", padx=10, pady=(8, 4))

        ttk.Button(grp_roteiro, text="Abrir roteiro...",
                   command=self.abrir_roteiro).grid(row=0, column=0, **pad)
        self.lbl_arquivo = ttk.Label(grp_roteiro,
                                     text="(nenhum roteiro carregado)")
        self.lbl_arquivo.grid(row=0, column=1, sticky="w", **pad)

        self.var_dry = tk.BooleanVar(value=True)
        ttk.Checkbutton(grp_roteiro, text="Dry-run (simular)",
                        variable=self.var_dry).grid(row=0, column=2, **pad)

        self.btn_run = ttk.Button(grp_roteiro, text="EXECUTAR",
                                  command=self.executar, style="Accent.TButton")
        self.btn_run.grid(row=0, column=3, **pad)
        grp_roteiro.columnconfigure(1, weight=1)

        grp_emerg = ttk.LabelFrame(self.root, text="Emergencia (ou ESC 3x)")
        grp_emerg.pack(fill="x", padx=10, pady=4)

        ttk.Button(grp_emerg, text="PARAR TUDO",
                   command=self._parar_tudo).grid(row=0, column=0, **pad)
        ttk.Button(grp_emerg, text="Resetar",
                   command=self._reset_emergencia).grid(row=0, column=1, **pad)

        grp_cap = ttk.LabelFrame(self.root, text="Capturas e gravacao")
        grp_cap.pack(fill="x", padx=10, pady=4)

        ttk.Button(grp_cap, text="Gravar cliques...",
                   command=self.gravar_cliques).grid(row=0, column=0, **pad)
        ttk.Button(grp_cap, text="Capturar tela",
                   command=self.capturar_agora).grid(row=0, column=1, **pad)
        ttk.Button(grp_cap, text="Pasta de capturas...",
                   command=self.escolher_pasta_capturas).grid(row=0, column=2, **pad)
        self.lbl_capdir = ttk.Label(grp_cap, text=self._nome_capdir())
        self.lbl_capdir.grid(row=0, column=3, sticky="w", **pad)
        grp_cap.columnconfigure(3, weight=1)

        meio = ttk.Frame(self.root)
        meio.pack(fill="both", expand=True, padx=10, pady=(4, 0))

        ttk.Label(meio, text="Feed de execucao:").pack(anchor="w")
        self.txt_feed = tk.Text(meio, height=16, state="disabled",
                                font=("Consolas", 10))
        self.txt_feed.pack(fill="both", expand=True)

        baixo = ttk.Frame(self.root)
        baixo.pack(fill="x", padx=10, pady=8)
        self.lbl_stats = ttk.Label(baixo, text="-")
        self.lbl_stats.pack(anchor="w")
        self.lbl_status = ttk.Label(baixo, text="Status: idle")
        self.lbl_status.pack(anchor="e")
        self._atualiza_stats()

    # ------------------------------------------------------------------
    def abrir_roteiro(self):
        # Janela nativa do Windows, ja aberta em scripts\
        path = selecionar_arquivo(pasta="scripts")
        if path:
            self.script_path = path
            self.lbl_arquivo.config(text=os.path.basename(path))

    # ------------------------------------------------------------------
    def executar(self):
        if not self.script_path:
            messagebox.showwarning("Sem roteiro", "Carregue um roteiro JSON antes.")
            return
        if self.runner_thread and self.runner_thread.is_alive():
            messagebox.showwarning("Ocupado", "Um roteiro ja esta em execucao.")
            return
        if self.emergency.is_triggered():
            messagebox.showerror("Emergencia ativa",
                                "Reset a emergencia antes de executar.")
            return

        modo_real = not self.var_dry.get()
        if modo_real and not messagebox.askyesno(
                "CONFIRMACAO",
                "Executar em modo REAL (mouse/teclado serao controlados)?\n\n"
                "ESC 3x interrompe tudo."):
            return

        self.config.dry_run = self.var_dry.get()
        self._feed(f"=== executando {os.path.basename(self.script_path)} "
                   f"({'dry-run' if self.config.dry_run else 'REAL'}) ===")

        def roda():
            try:
                res = self.interpreter.run_file(self.script_path)
                msg = (f"CONCLUIDO ok={res.ok} executadas={res.executadas} "
                       f"bloqueadas={res.bloqueadas} {res.abort_reason}")
            except Exception as e:  # noqa: BLE001 - erro vira feed, nao crash
                msg = f"FALHOU: {e}"
            self.events.put(("fim", None, msg))

        self.runner_thread = threading.Thread(target=roda, daemon=True)
        self.runner_thread.start()
        self.lbl_status.config(text="Status: executando...")

    def _confirmar_sensivel(self, ac) -> bool:
        """Janela modal p/ acao sensivel; timeout = negada (fail-safe)."""
        res = {"ok": False}
        ev = threading.Event()

        def pergunta():
            res["ok"] = messagebox.askyesno(
                "ACAO SENSIVEL",
                f"Acao: {ac.get('tipo')}\n{ac}\n\nAprovar execucao?")
            ev.set()
        self.root.after(0, pergunta)
        ev.wait(timeout=self.config.confirmation_timeout_s)
        return res["ok"]

    # ------------------------------------------------------------------
    # Recorder + pasta de capturas (janelas nativas do Windows)
    # ------------------------------------------------------------------
    def gravar_cliques(self):
        """Grava cliques humanos; saiida escolhida em janela nativa
        ja aberta em scripts\\. F12 encerra a gravacao."""
        if self.runner_thread and self.runner_thread.is_alive():
            messagebox.showwarning("Ocupado", "Aguarde a execucao atual terminar.")
            return
        path = selecionar_arquivo(pasta="scripts", salvar=True,
                                  nome_default="gravacao.json")
        if not path:
            return
        self._feed("=== recorder armado: F12 INICIA, F10 ENCERRA ===")

        from agent.recorder.recorder import HumanRecorder
        rec = HumanRecorder(self.config, emergency=self.emergency)
        estado = {}

        def roda():
            if not rec.arm():
                self.events.put(("fim", None, "recorder: pynput indisponivel"))
                return
            self.events.put(("aviso", None,
                             "recorder armado: aperte F12 p/ iniciar"))
            import time as _t
            while not rec.is_stopped and not self.emergency.is_triggered():
                _t.sleep(0.1)
                if rec.is_recording and rec.click_count() and not estado.get("avisou"):
                    estado["avisou"] = True
                    self.events.put(("aviso", None,
                                     f"gravando... {rec.click_count()} cliques (F10 encerra)"))
            rec.stop()  # desarma listeners E restaura a janela do console
            if rec.save_script(path) is None:
                self.events.put(("fim", None,
                                 "0 cliques gravados - roteiro vazio NAO salvo"))
            else:
                self.events.put(("fim", None,
                                 f"gravado: {path} ({rec.click_count()} cliques)"))

        threading.Thread(target=roda, daemon=True).start()

    def capturar_agora(self):
        """Print imediato salvo em capturas (janela nativa define a pasta)."""
        def roda():
            try:
                import datetime as _dt
                nome = "print_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S") + ".png"
                path = self.interpreter._resolve_path(nome)
                self.refs.screen.capture_to_file(path)
                self.events.put(("aviso", None, f"print salvo: {path}"))
            except Exception as e:  # noqa: BLE001 - erro vira feed, nao crash
                self.events.put(("aviso", None, f"print FALHOU: {e}"))
        threading.Thread(target=roda, daemon=True).start()

    def escolher_pasta_capturas(self):
        """Janela nativa de PASTA, aberta em capturas\\.
        capturar_tela/ler_texto com caminho relativo salvam aqui."""
        pasta = selecionar_pasta(pasta="capturas")
        if pasta:
            self.config.capture_dir = pasta
            self.lbl_capdir.config(text=self._nome_capdir())
            self._feed(f"pasta de capturas: {pasta}")

    def _nome_capdir(self):
        if os.path.isabs(self.config.capture_dir):
            return self.config.capture_dir
        return os.path.join(".", self.config.capture_dir)

    # ------------------------------------------------------------------
    # Emergencia
    # ------------------------------------------------------------------
    def _parar_tudo(self):
        self.emergency.trigger()
        self._feed("*** EMERGENCIA DISPARADA PELO PAINEL ***")

    def _reset_emergencia(self):
        self.emergency.reset()
        self._feed("emergencia resetada pelo operador")

    # ------------------------------------------------------------------
    # Feed + estatisticas
    # ------------------------------------------------------------------
    def _drain_events(self):
        try:
            while True:
                fase, ac, motivo = self.events.get_nowait()
                if fase == "fim":
                    self._feed(f"=== {motivo} ===")
                    self.lbl_status.config(text="Status: idle")
                    self._atualiza_stats()
                elif ac is None:
                    self._feed(f"* {motivo}")
                else:
                    resumo = {k: ac.get(k) for k in ("tipo", "x", "y",
                              "combinacao", "texto", "segundos") if k in ac}
                    extra = f' ("{motivo}")' if motivo and motivo != "ok" else ""
                    self._feed(f"[{fase}] {resumo}{extra}")
        except queue.Empty:
            pass
        self.root.after(200, self._drain_events)

    def _feed(self, linha: str):
        self.txt_feed.config(state="normal")
        self.txt_feed.insert("end", linha + "\n")
        self.txt_feed.see("end")
        self.txt_feed.config(state="disabled")

    def _atualiza_stats(self):
        s = self.logger.stats()
        self.lbl_stats.config(
            text=f"Total: {s['total']}  |  Permitidas: {s['allowed']}  |  "
                 f"Bloqueadas: {s['blocked']}  |  Executadas: {s['executed']}")


def main():
    root = tk.Tk()
    Dashboard(root)
    root.mainloop()


if __name__ == "__main__":
    main()

'@
    "tests\test_control.py" = @'
"""
test_control.py - Testes das camadas de controle (mouse/teclado) com fakes.
Nenhum hardware e tocado; o backend fake registra tudo o que foi chamado.
"""

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agent.control.mouse import MouseController
from agent.control.keyboard import KeyboardController


class FakePyAutoGUI:
    """Registra chamadas como pyautogui faria, sem tocar em hardware."""
    def __init__(self):
        self.calls = []
        self.pos = (0, 0)

    def moveTo(self, x, y):
        self.pos = (x, y)
        self.calls.append(("moveTo", x, y))

    def click(self, clicks=1, button="left", interval=0):
        self.calls.append(("click", self.pos, button, clicks))

    def mouseDown(self, button="left"):
        self.calls.append(("mouseDown", self.pos, button))

    def mouseUp(self, button="left"):
        self.calls.append(("mouseUp", self.pos, button))

    def press(self, key):
        self.calls.append(("press", key))

    def hotkey(self, *keys):
        self.calls.append(("hotkey", keys))

    def position(self):
        return self.pos


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # --- Mouse ---
    fake = FakePyAutoGUI()
    m = MouseController(backend=fake)
    m.move(100, 200)
    check("move teleporta para (100,200)", fake.pos == (100, 200))
    m.click(300, 400, button="right")
    check("clique direito move+clique",
          fake.calls == [("moveTo", 100, 200), ("moveTo", 300, 400),
                         ("click", (300, 400), "right", 1)])
    m.double_click(10, 20)
    check("duplo clique usa clicks=2", fake.calls[-1] == ("click", (10, 20), "left", 2))
    m.click(5, 5, interval_s=0.01)
    check("clique com intervalo nao falha", fake.calls[-1][0] == "click")

    # --- Clique direito ROBUSTO (regressao do bug real 26/09/2026) ---
    fake2 = FakePyAutoGUI()
    m2 = MouseController(backend=fake2)
    m2.right_click(930, 226, settle_s=0.0, hold_s=0.0)  # instantaneo
    check("clique direito: settle+hold via mouseDown/mouseUp (nao batelada)",
          fake2.calls == [("moveTo", 930, 226),
                           ("mouseDown", (930, 226), "right"),
                           ("mouseUp", (930, 226), "right")])
    check("clique direito: ordem teleporta->down->up",
          [c[0] for c in fake2.calls] == ["moveTo", "mouseDown", "mouseUp"])
    m2.right_click(10, 10)  # defaults: dorme 0.1s no total
    check("clique direito com defaults tambem funciona",
          fake2.calls[-2] == ("mouseDown", (10, 10), "right"))

    # --- Teclado ---
    fake_kb = FakePyAutoGUI()
    sem_dormir = lambda s: None  # noqa: E731 - sleep injetado = teste instant?neo
    kb = KeyboardController(backend=fake_kb, delay_min_ms=50,
                           delay_max_ms=50, sleep_fn=sem_dormir)
    kb.type_text("abc")
    check("digita 3 chars, 1 press cada",
          fake_kb.calls == [("press", "a"), ("press", "b"), ("press", "c")])
    kb.press_combo("ctrl+s")
    check("combo duplo usa hotkey", fake_kb.calls[-1] == ("hotkey", ("ctrl", "s")))
    kb.press_combo("enter")
    check("tecla unica usa press", fake_kb.calls[-1] == ("press", "enter"))
    kb.press_combo("  ctrl +  shift  + t  ")
    check("combo com espacos e maiusculas normaliza",
          fake_kb.calls[-1] == ("hotkey", ("ctrl", "shift", "t")))

    # --- Delay humanizado respeita min/max ---
    dormidas = []
    kb2 = KeyboardController(backend=FakePyAutoGUI(), delay_min_ms=100,
                             delay_max_ms=100, sleep_fn=dormidas.append)
    kb2.type_text("xyz")
    check("3 sleeps de ~100ms entre teclas", dormidas == [0.1, 0.1, 0.1])

    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("[OK]" if ok else "[FALHOU]"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)

'@
    "tests\test_menu_paths.py" = @'
"""
test_menu_paths.py - Exercita os CAMINHOS REAIS das opcoes do menu.

Licao de um bug real (26/09/2026, opcao [5] do usuario): o loop do
recorder usava 'emergencia.triggered' - atributo QUE NAO EXISTE em
EmergencyStop (o metodo publico e is_triggered()) - AttributeError
na cara do usuario. A REGRA DE OURO de testar todas as opcoes do
menu existia (test_menu_agente.py) mas era estatica sobre o .ps1;
o bug estava no PYTHON chamado pelo menu.

Este modulo fecha a lacuna: varre o main.py (entrypoint de TODAS
as opcoes Python do menu: [3], [4], [5], [6]) via AST e confere
que CADA atributo acessado numa variavel construida por uma classe
do projeto existe de verdade na API dessa classe (metodos,
properties e self.<attr> publicos). E um mini-linter semantico - a
mesma classe de ver que um IDE faz, mas automatizada no run_all.

O sandbox nao importa main.py (imports de pyautogui/pywinauto),
por isso a analise e por AST: cobre todos os caminhos de codigo
sem rodar o Windows.
"""

import ast
import os
import re

BASE = os.path.join(os.path.dirname(__file__), "..")
MAIN_PY = os.path.join(BASE, "main.py")


def _mapa_imports(arvore):
    """ClassName -> arquivo do modulo (so imports 'from agent...')."""
    mapa = {}
    for no in ast.walk(arvore):
        if isinstance(no, ast.ImportFrom) and no.module and \
                no.module.startswith("agent."):
            caminho = no.module.replace(".", "/") + ".py"
            for alias in no.names:
                mapa[alias.asname or alias.name] = caminho
    return mapa


def _api_da_classe(arquivo, classe):
    """API publica da classe: metodos, @property e self.<attr>."""
    # arquivos do projeto podem ter acentos em docstrings (Python le
    # UTF-8 nativamente - a regra de ASCII puro e para .ps1/.bat)
    try:
        texto = open(arquivo, encoding="ascii").read()
    except UnicodeDecodeError:
        texto = open(arquivo, encoding="utf-8").read()
    arvore = ast.parse(texto)
    for no in arvore.body:
        if isinstance(no, ast.ClassDef) and no.name == classe:
            api = set()
            # @dataclass: campos declarados como 'nome: tipo = valor'
            # (AnnAssign com alvo Name no corpo da classe)
            for item in no.body:
                if isinstance(item, ast.AnnAssign) and \
                        isinstance(item.target, ast.Name) and \
                        not item.target.id.startswith("_"):
                    api.add(item.target.id)
            for item in no.body:
                if isinstance(item, ast.FunctionDef):
                    api.add(item.name)
                    if any(isinstance(d, ast.Name) and d.id == "property"
                           for d in item.decorator_list):
                        pass  # property e acessada como attr: ja esta no set
                for sub in ast.walk(item):
                    if isinstance(sub, ast.Assign):
                        for alvo in sub.targets:
                            if isinstance(alvo, ast.Attribute) and \
                                    isinstance(alvo.value, ast.Name) and \
                                    alvo.value.id == "self" and \
                                    not alvo.attr.startswith("_"):
                                api.add(alvo.attr)
            return api
    return set()


def _vars_por_classe(arvore, mapa_imports):
    """var -> classe, para 'var = Classe(...)' em QUALQUER escopo."""
    vars_ = {}
    for no in ast.walk(arvore):
        if isinstance(no, ast.Assign) and len(no.targets) == 1 and \
                isinstance(no.targets[0], ast.Name) and \
                isinstance(no.value, ast.Call) and \
                isinstance(no.value.func, ast.Name) and \
                no.value.func.id in mapa_imports:
            vars_[no.targets[0].id] = no.value.func.id
    return vars_


def _titulo_janela_ativa_rapido():
    """Chama a funcao real: no sandbox (Linux) deve voltar '' na hora."""
    import sys
    sys.path.insert(0, os.path.join(BASE))
    import time as _t
    from agent.runtime import titulo_janela_ativa
    ini = _t.monotonic()
    titulo = titulo_janela_ativa()
    return (_t.monotonic() - ini) < 1.0 and titulo == ""


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    fonte = open(MAIN_PY, encoding="ascii").read()
    arvore = ast.parse(fonte)
    mapa_imports = _mapa_imports(arvore)
    vars_ = _vars_por_classe(arvore, mapa_imports)

    check("main.py: AST valido", True)
    check("main.py: importa EmergencyStop (opcoes [3]/[4]/[5] usam)",
          "EmergencyStop" in mapa_imports)
    check("main.py: importa HumanRecorder (opcao [5])",
          "HumanRecorder" in mapa_imports)
    check("main.py: variaveis construidas por classes do projeto detectadas",
          len(vars_) >= 2 and "emergencia" in vars_ and "rec" in vars_)

    # === CRUZAMENTO: cada <var>.<attr> acessado existe na API real ===
    acessos = set()
    for no in ast.walk(arvore):
        if isinstance(no, ast.Attribute) and \
                isinstance(no.value, ast.Name) and \
                no.value.id in vars_:
            acessos.add((no.value.id, no.attr))

    check("main.py: ha acessos a checar (linter nao esta cego)",
          len(acessos) >= 5)

    erros = []
    cobertos = 0
    for var, attr in sorted(acessos):
        classe = vars_[var]
        arquivo = os.path.join(BASE, mapa_imports[classe])
        if not os.path.exists(arquivo):
            erros.append(f"{var}.{attr}: arquivo {arquivo} nao existe")
            continue
        api = _api_da_classe(arquivo, classe)
        if attr not in api:
            erros.append(f"{var}.{attr}: NAO existe na API de {classe} "
                         f"(opcoes: {sorted(api)[:8]}...)")
        else:
            cobertos += 1

    check(f"CRUZAMENTO: TODOS os {len(acessos)} acessos existem nas APIs "
          f"reais ({cobertos} confirmados)", len(erros) == 0)
    for e in erros:
        check("  erro: " + e, False)

    # === QuickEdit (bug real 26/09/2026: clique do usuario no console
    #     congela o processo - 'deu uma bloqueada', ESC 3x pareceu morto) ===
    rec_mod = open(os.path.join(BASE, "agent", "recorder", "recorder.py"),
                   encoding="ascii").read()
    check("console: disable_quickedit existe no recorder",
          "def disable_quickedit" in rec_mod and
          "ENABLE_QUICK_EDIT" in rec_mod and
          "ENABLE_EXTENDED_FLAGS" in rec_mod)
    check("console: main.py DESATIVA QuickEdit antes de tudo",
          "disable_quickedit()" in fonte and
          fonte.index("disable_quickedit()") <
          fonte.index('ap = argparse.ArgumentParser'))
    check("console: dashboard tambem desativa QuickEdit",
          "quickedit_off()" in open(os.path.join(BASE, "dashboard", "app.py"),
                                    encoding="ascii").read())
    check("[4]: retorno do emergencia.start() VERIFICADO (listener)",
          "if not emergencia.start():" in fonte)
    check("[4]: banner avisa kill switch do canto (independe de foco)",
          "canto sup. esquerdo" in fonte)

    # === modo REAL (opcao [4]): congelamento + UX (bug real 26/09/2026,
    #     o agente travou ANTES do primeiro clique, console parado) ===
    rt = open(os.path.join(BASE, "agent", "runtime.py"),
              encoding="ascii").read()
    check("[3]/[4]: titulo_janela_ativa usa Win32 nativo (GetForegroundWindow)",
          "GetForegroundWindow" in rt and "GetWindowTextW" in rt)
    check("[3]/[4]: REGRESSAO congelamento: SEM pywinauto UIA no titulo",
          "backend=\"uia\"" not in rt and "get_active()" not in rt)
    check("[3]/[4]: titulo_janela_ativa responde rapido no sandbox",
          _titulo_janela_ativa_rapido())
    check("[4]: EXATAMENTE UMA confirmacao Continuar no main.py (sem dupla)",
          fonte.count('input("Continuar? [s/N] ")') == 1)
    check("[4]: minimiza console ANTES de executar no modo REAL",
          fonte.index("minimize_console()") <
          fonte.index("interpreter.run_file(args.roteiro)"))
    check("[4]: restaura console no fim E no finally (ESC/erro tambem)",
          fonte.count("restore_console()") >= 2 and
          "restore_console()" in fonte.split("finally:")[1])
    check("[4]: minimizar vem do recorder (mesmo codigo do F12/F10)",
          "from agent.recorder.recorder import minimize_console, restore_console"
          in fonte)

    # === regressao do bug real: o typo NAO pode voltar ===
    check("BUG REAL [5]: 'emergencia.triggered' (attr inexistente) ausente",
          "emergencia.triggered" not in re.sub(r"is_triggered", "", fonte))
    check("[5]: loop usa o metodo publico is_triggered()",
          "emergencia.is_triggered()" in fonte)
    check("[5]: rec.is_stopped e property real do HumanRecorder",
          "rec.is_stopped" in fonte and "is_stopped" in
          _api_da_classe(os.path.join(BASE, mapa_imports["HumanRecorder"]),
                         "HumanRecorder"))

    return results


if __name__ == "__main__":
    import sys
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)

'@
    "tests\test_dashboard_ui.py" = @'
"""
test_dashboard_ui.py - Testes estaticos do dashboard/app.py (Tkinter).

O sandbox de testes NAO tem libtk instalada (tkinter falha ao
importar: "libtk8.6.so: cannot open shared object file"), e o
projeto e Windows-only - mesma limitacao ja documentada para
sincronizar_github.ps1/gerar_exe.ps1. Estrategia: checagens
estaticas sobre o CODIGO-FONTE (AST + texto), a mesma usada em
test_sed_gerar_exe.py e test_sincronizar_token.py.

Motivacao (bug real 26/09/2026, screenshot do usuario): o botao
"Capturar tela agora" e o rotulo lbl_capdir ocupavam a MESMA
celula do grid (row=0, column=2) - colisao real do Tkinter que
desenhava os dois textos um sobre o outro ("Cap. capturas.jpg"
embaralhado na tela). Corrigido com reagrupamento em LabelFrame
e colunas distintas. Tambem adicionado: minimizar a janela do
console (CMD que o Start-Process abre) enquanto o dashboard esta
ativo, restaurando ao fechar - reuso do mecanismo do HumanRecorder.
"""

import ast
import os
import re

APP_PY = os.path.join(os.path.dirname(__file__), "..",
                      "dashboard", "app.py")


def _texto():
    with open(APP_PY, encoding="ascii") as f:
        return f.read()


def _grid_cells_por_frame(arvore, texto):
    """Mapeia, por GRUPO (frame/labelframe atual), o conjunto de
    (row, column) usados em .grid(...) - deteccao de colisao
    estatica (mesma logica do bug real: 2 widgets, mesma celula).

    O codigo widget->.grid() se estende por varias linhas (o
    construtor e o .grid() ficam em linhas diferentes), entao a
    varredura acompanha sequencialmente qual e o "grupo atual"
    (a ultima variavel de frame criada com ttk.Frame/ttk.LabelFrame)
    e atribui a ela toda .grid(row=N, column=M) encontrada depois,
    ate o proximo frame ser criado - reflete exatamente como o
    arquivo esta estruturado (bloco por bloco).
    """
    celulas = {}
    grupo_atual = None
    for linha in texto.splitlines():
        m_frame = re.search(
            r"^\s*(\w+)\s*=\s*ttk\.(?:Label)?Frame\(", linha)
        if m_frame:
            grupo_atual = m_frame.group(1)
            continue
        m = re.search(r"\.grid\(row=(\d+),\s*column=(\d+)", linha)
        if not m:
            continue
        chave = (grupo_atual, int(m.group(1)), int(m.group(2)))
        celulas.setdefault(chave, 0)
        celulas[chave] += 1
    return celulas


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # regressao v018: dashboard desativa QuickEdit do console
    _src = open(os.path.join(os.path.dirname(__file__), "..", "dashboard",
                             "app.py"), encoding="ascii").read()
    check("dashboard: importa disable_quickedit e CHAMA quickedit_off()",
          "disable_quickedit" in _src and "quickedit_off()" in _src)
    t = _texto()

    # --- AST valido (arquivo Windows-only, mas a SINTAXE e Python puro) ---
    arvore = ast.parse(t)
    check("dashboard/app.py: AST valido (sintaxe Python correta)",
          arvore is not None)

    # --- bug real: nenhuma celula de grid duplicada (colisao) ---
    celulas = _grid_cells_por_frame(arvore, t)
    duplicadas = {k: v for k, v in celulas.items() if v > 1}
    check("grid: nenhuma celula (frame, row, col) usada 2x (colisao real corrigida)",
          len(duplicadas) == 0)
    check("grid: pelo menos 8 widgets posicionados (grupos nao vazios)",
          sum(celulas.values()) >= 8)

    # --- reagrupamento em LabelFrame (pedido do usuario) ---
    check("layout: 3 grupos LabelFrame (Roteiro/Emergencia/Capturas)",
          t.count("ttk.LabelFrame(") == 3)
    check("layout: grupo Roteiro existe",
          'text="Roteiro"' in t)
    check("layout: grupo Emergencia existe e cita ESC 3x",
          'text="Emergencia (ou ESC 3x)"' in t)
    check("layout: grupo Capturas existe",
          'text="Capturas e gravacao"' in t)

    # --- textos de botao mais curtos (sem duplicar contexto do grupo) ---
    check("botao emergencia: 'PARAR TUDO' sem repetir '(emergencia)' 2x",
          'text="PARAR TUDO"' in t and
          t.count("(emergencia)") <= 1)  # so no titulo do grupo
    check("botao reset: texto curto 'Resetar'",
          'text="Resetar"' in t)
    check("botao captura: 'Capturar tela' (sem 'agora' redundante)",
          'text="Capturar tela"' in t)
    check("checkbox dry-run: texto encurtado",
          'text="Dry-run (simular)"' in t)

    # --- minimizar/restaurar console (novo pedido do usuario) ---
    check("console: importa minimize_console/restore_console do recorder (DRY)",
          "from agent.recorder.recorder import minimize_console, restore_console" in t)
    check("console: window_ctl injetavel no construtor (testavel, como o Recorder)",
          "def __init__(self, root: tk.Tk, window_ctl=None):" in t)
    check("console: minimiza ao abrir o dashboard",
          "self.window_ctl.minimize()" in t)
    check("console: restaura ao fechar (WM_DELETE_WINDOW -> _ao_fechar)",
          'root.protocol("WM_DELETE_WINDOW", self._ao_fechar)' in t and
          "self.window_ctl.restore()" in t)
    check("console: fechar realmente destroi a janela (nao so restaura)",
          "self.root.destroy()" in t)

    # --- regressoes das regras do projeto ---
    check("dashboard/app.py: 100% ASCII", all(b < 128 for b in
          open(APP_PY, "rb").read()))
    check("dashboard: montar_stack ainda chamado com keywords (bug da v007)",
          "confirmation_fn=self._confirmar_sensivel" in t and
          "on_event=" in t)

    return results


if __name__ == "__main__":
    import sys
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)

'@

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "agent\recorder\recorder.py" = "2F8667C8D02744DA25FADD6AACC0CC1EEE1834603A0627BA04E903DBA42CEC6B"
    "agent\control\mouse.py" = "7E30B7809C4F4B068F58F23D54C367092E7A94E904CC0E49BAA465E0C291CD22"
    "main.py" = "D008C269310237566EDF339F87DE5BCEEEFCF3912EFDEF93CDB74F889632DEAF"
    "dashboard\app.py" = "C8AEA0E609AC194E6AEBD4E9BA9C7E5DFFDD1FA97F7203BA3A105363197D3078"
    "tests\test_control.py" = "F82C336E74FCDA1CFE29D0A56AAA53086C46887DCDF3BF3380C5397215113B61"
    "tests\test_menu_paths.py" = "CDDDE47DDB4147E80EFF4BFD20CAA69C326122149EED9F8A1A1E00E7E5CBB1DC"
    "tests\test_dashboard_ui.py" = "E642E5B47D278E66657D6C75BDECCB485D1A09A247546845B041D998503ED654"

}

# --- confirmacao: o que sera tocado ---
Write-Host "Este patch grava os seguintes arquivos:" -ForegroundColor Yellow
foreach ($rel in $Arquivos.Keys) {
    $dest = Join-Path $Raiz $rel
    $estado = "NOVO"
    if (Test-Path $dest) { $estado = "atualiza" }
    Write-Host ("  [{0}] {1}" -f $estado, $rel)
}
Write-Host ""
$conf = Read-Host "Aplicar? [s/N]"
if ($conf -ne "s") {
    Write-Host "Cancelado. Nada foi alterado." -ForegroundColor Yellow
    Read-Host "Pressione ENTER para fechar" | Out-Null
    exit 0
}
Write-Host ""

# --- pasta patches e versao ---
$Patches = Join-Path $Raiz "patches"
if (-not (Test-Path $Patches)) {
    New-Item -ItemType Directory -Path $Patches | Out-Null
    Write-Host "Pasta patches\ criada." -ForegroundColor Green
}
$seq = 1 + @(Get-ChildItem -Path $Patches -Directory -Filter "v*" -ErrorAction SilentlyContinue).Count
$data = Get-Date -Format "yyyy-MM-dd_HHmm"
$versao = "v{0:d3}_{1}" -f $seq, $data
$VerDir = Join-Path $Patches $versao
New-Item -ItemType Directory -Path $VerDir | Out-Null
Write-Host "Versao deste patch: $versao" -ForegroundColor Cyan
Write-Host ""

# --- backup antigos, gravar novos, versionar novos ---
$ok = $true
$relats = @()
foreach ($rel in $Arquivos.Keys) {
    $dest = Join-Path $Raiz $rel
    $dirDest = [IO.Path]::GetDirectoryName($dest)
    if (-not (Test-Path $dirDest)) {
        New-Item -ItemType Directory -Path $dirDest -Force | Out-Null
    }

    # backup do arquivo atual (se existir) -> <ver>\anteriores\
    if (Test-Path $dest) {
        $bk = Join-Path $VerDir ("anteriores\" + $rel)
        $dirBk = [IO.Path]::GetDirectoryName($bk)
        if (-not (Test-Path $dirBk)) {
            New-Item -ItemType Directory -Path $dirBk -Force | Out-Null
        }
        Copy-Item $dest $bk -Force
    }

    # grava o conteudo corrigido
    $conteudo = $Arquivos[$rel]
    [IO.File]::WriteAllText($dest, $conteudo, [Text.Encoding]::ASCII)

    # verificacao: SHA-256 do gravado == SHA-256 esperado
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash
    if ($h -eq $Hashes[$rel]) {
        Write-Host ("[OK] {0} (sha256 {1}...)" -f $rel, $h.Substring(0, 8)) -ForegroundColor Green
        $relats += "OK"
    } else {
        Write-Host ("[ERRO] {0}: sha256 divergente" -f $rel) -ForegroundColor Red
        Write-Host ("       esperado {0}" -f $Hashes[$rel]) -ForegroundColor Red
        Write-Host ("       gravado {0}" -f $h) -ForegroundColor Red
        $relats += "ERRO"
        $ok = $false
    }

    # copia versionada do arquivo novo -> <ver>\
    $cp = Join-Path $VerDir $rel
    $dirCp = [IO.Path]::GetDirectoryName($cp)
    if (-not (Test-Path $dirCp)) {
        New-Item -ItemType Directory -Path $dirCp -Force | Out-Null
    }
    Copy-Item $dest $cp -Force
}

# --- copia versionada de si mesmo ---
$patchVersao = Join-Path $VerDir ("patch_" + $versao + ".ps1")
Copy-Item -LiteralPath $PSCommandPath $patchVersao -Force

# --- registro ---
$registro = Join-Path $Patches "registro.csv"
if (-not (Test-Path $registro)) {
    "versao;data;arquivos;resultado" | Out-File -Encoding ascii $registro
}
$linha = "{0};{1};{2};{3}" -f $versao, (Get-Date -Format "yyyy-MM-dd HH:mm"), ($Arquivos.Keys -join "|"), ($relats -join " ")
Add-Content -Path $registro -Value $linha -Encoding ascii

# --- resumo, pausa e autodestruicao ---
Write-Host ""
if ($ok) {
    Write-Host "Patch $versao aplicado com sucesso." -ForegroundColor Green
} else {
    Write-Host "Patch aplicado COM ERROS - veja acima." -ForegroundColor Red
}
Write-Host "Versionado em: patches\$versao"
Write-Host "Registro:      patches\registro.csv"
Write-Host "Rollback:      copie de patches\$versao\anteriores\"
Read-Host "Pressione ENTER para finalizar (o patch.ps1 da raiz sera apagado)" | Out-Null

# autodestruicao: a copia versionada permanece em patches\<ver>\
try {
    Remove-Item -LiteralPath $PSCommandPath -Force
    Write-Host "patch.ps1 apagado da raiz (copia versionada preservada)." -ForegroundColor Green
} catch {
    Write-Host "Nao consegui apagar o patch.ps1 (arquivo em uso)." -ForegroundColor Yellow
    Write-Host "Apague-o manualmente quando quiser." -ForegroundColor Yellow
}
exit 0
