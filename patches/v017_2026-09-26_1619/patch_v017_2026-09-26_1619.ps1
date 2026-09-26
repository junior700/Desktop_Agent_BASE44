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

    "agente.ps1" = @'
# ============================================================
#  AGENTE DESKTOP - menu principal (PowerShell)
#  Todos os caminhos sao relativos a pasta deste script.
#  Executar com:  .\agente.ps1
#  Se bloqueado:  powershell -ExecutionPolicy Bypass -File .\agente.ps1
# ============================================================

$Proj = $PSScriptRoot
$Venv = Join-Path $Proj ".venv\Scripts\python.exe"

function Menu {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "       AGENTE DE DESKTOP - MENU" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    if (-not (Test-Path $Venv)) {
        Write-Host "`n  [AVISO] .venv nao encontrado. Rode a opcao [1] primeiro.`n" -ForegroundColor Yellow
    }
    Write-Host "`n  [1] Instalar ambiente (.venv + dependencias)"
    Write-Host "  [2] Rodar testes automatizados"
    Write-Host "  [3] Executar roteiro (dry-run - seguro)"
    Write-Host "  [4] Executar roteiro (REAL - controla mouse/teclado)"
    Write-Host "  [5] Gravar cliques humanos (Human Recorder)"
    Write-Host "  [6] Abrir dashboard"
    Write-Host "  [7] Sincronizar com GitHub (sincronizar_github.ps1)"
    Write-Host "  [8] Gerar publicar_github.exe (fonte .bin em restrict\)"
    Write-Host "  [9] Aplicar patch pendente (patch.ps1 na raiz)"
    Write-Host "  [10] Instalar pytesseract (se ausente)"
    Write-Host "  [0] Sair`n"
}

# Janela NATIVA do Windows para escolher arquivo (aberta em scripts\)
function Escolher-Roteiro {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Selecionar roteiro JSON"
    $dlg.InitialDirectory = Join-Path $Proj "scripts"
    $dlg.Filter = "Roteiros JSON (*.json)|*.json|Todos os arquivos (*.*)|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.FileName
    }
    return $null
}

# Janela NATIVA do Windows para SALVAR gravacao (aberta em scripts\)
function Escolher-Saida-Gravacao {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = "Salvar roteiro gravado"
    $dlg.InitialDirectory = Join-Path $Proj "scripts"
    $dlg.FileName = "gravacao.json"
    $dlg.Filter = "Roteiros JSON (*.json)|*.json"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.FileName
    }
    return $null
}

# Verifica de VERDADE se as dependencias instalaram: importa cada
# lib critica pelo proprio python do venv e checa a ENGINE Tesseract
# (pip instala o pytesseract - wrapper Python - mas NAO o programa
# tesseract.exe, que e separado; pytesseract sem engine quebra em
# tempo de execucao com TesseractNotFoundError)
function Verificar-Deps {
    Write-Host "`n--- Verificacao das dependencias ---"
    & $Venv -c "import importlib.util as iu; mods=['pyautogui','pywinauto','pynput','PIL','pytesseract','cv2','jsonschema']; f=[m for m in mods if iu.find_spec(m) is None]; print('FALTAM: '+', '.join(f)) if f else print('TODAS AS 7 LIBS PYTHON: OK')"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: python do venv nao rodou a verificacao." -ForegroundColor Red
    }
    $eng = where.exe tesseract 2>$null
    if ($eng) {
        Write-Host "ENGINE Tesseract OCR: OK ($eng)"
    }
    else {
        Write-Host "ENGINE Tesseract OCR: NAO ENCONTRADA no PATH." -ForegroundColor Yellow
        Write-Host "O pytesseract (wrapper) esta instalado, mas o PROGRAMA"
        Write-Host "tesseract.exe e separado. Sem ele, OCR falha em tempo de"
        Write-Host "execucao. Instale em:"
        Write-Host "  https://github.com/UB-Mannheim/tesseract/wiki"
    }
    Write-Host "--- Fim da verificacao ---`n"
}

# NAO usar 'break' dentro do switch: no PowerShell o break e consumido
# pelo switch (nao pelo while) - "0 Sair" so redesenhava o menu.
# Saida controlada por flag.
$sair = $false
while (-not $sair) {
    Menu
    $op = Read-Host "Escolha"
    switch ($op) {
        "1" {
            # Bug real do usuario (26/09/2026): py -3.12 RODOU e o venv
            # falhou com "Errno 13 Permission denied python.exe" (venv em
            # uso), mas o script reportava "Python 3.12 nao encontrado" -
            # diagnostico MENTIROSO. Agora cada falha tem sua causa real:
            Push-Location $Proj
            try {
                # [a] Python 3.12 existe mesmo? (erro separado, message clara)
                py -3.12 --version 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "ERRO: Python 3.12 NAO esta instalado (py -3.12)." -ForegroundColor Red
                    Write-Host "Baixe em https://www.python.org/downloads/ e marque" -ForegroundColor Yellow
                    Write-Host "'py launcher' no instalador (opcao padrao)." -ForegroundColor Yellow
                }
                elseif (Test-Path $Venv) {
                    # [b] .venv SAUDAVEL: nao recria! Recriar com o ambiente
                    # em uso e a causa do Errno 13 (python.exe travado);
                    # so reconfere as dependencias
                    Write-Host ".venv ja existe - reconfirmando dependencias..."
                    & $Venv -m pip install --upgrade pip
                    & $Venv -m pip install -r requirements.txt
                    Verificar-Deps
                }
                else {
                    # [c] .venv AUSENTE ou QUEBRADO (pasta existe sem
                    # python.exe - criacao interrompida no meio)
                    $criar = $true
                    $venvDir = Join-Path $Proj ".venv"
                    if (Test-Path $venvDir) {
                        Write-Host "Pasta .venv existe mas esta QUEBRADA (sem python.exe)." -ForegroundColor Yellow
                        Write-Host "Apagando e recriando do zero..."
                        try {
                            Remove-Item -Recurse -Force $venvDir -ErrorAction Stop
                        }
                        catch {
                            Write-Host "ERRO: .venv travado (arquivo em uso). Feche o" -ForegroundColor Red
                            Write-Host "dashboard, editores ou scripts que usam o" -ForegroundColor Red
                            Write-Host "ambiente e rode a opcao [1] de novo." -ForegroundColor Red
                            $criar = $false
                        }
                    }
                    if ($criar) {
                        Write-Host "Criando ambiente virtual..."
                        $saidaVenv = (py -3.12 -m venv .venv 2>&1 | Out-String).Trim()
                        # verificacao REAL: o python.exe do venv existe agora?
                        if (Test-Path $Venv) {
                            & $Venv -m pip install --upgrade pip
                            & $Venv -m pip install -r requirements.txt
                            Verificar-Deps
                        }
                        else {
                            Write-Host "ERRO ao criar o .venv. Motivo REAL:" -ForegroundColor Red
                            Write-Host $saidaVenv
                            Write-Host "(Permission denied = algo usando/travando a pasta:" -ForegroundColor Yellow
                            Write-Host "feche programas do .venv, ou antivrus/OneDrive;" -ForegroundColor Yellow
                            Write-Host "rode [1] de novo apos liberar)" -ForegroundColor Yellow
                        }
                    }
                }
            } finally { Pop-Location }
            Pause
        }
        "2" {
            if (Test-Path $Venv) { & $Venv (Join-Path $Proj "tests\run_all.py") }
            else { Write-Host "Rode a opcao [1] primeiro." -ForegroundColor Yellow }
            Pause
        }
        "3" {
            $rot = Escolher-Roteiro
            if ($rot) {
                if (Test-Path $Venv) { & $Venv (Join-Path $Proj "main.py") $rot }
                else { Write-Host "Rode a opcao [1] primeiro." -ForegroundColor Yellow }
            }
            Pause
        }
        "4" {
            Write-Host "ATENCAO: modo REAL. O agente vai controlar mouse e teclado." -ForegroundColor Yellow
            Write-Host "ESC 3x interrompe tudo imediatamente."
            Write-Host "O main.py pedira confirmacao antes de executar."
            $rot = Escolher-Roteiro
            if ($rot) {
                if (Test-Path $Venv) { & $Venv (Join-Path $Proj "main.py") $rot --real }
                else { Write-Host "Rode a opcao [1] primeiro." -ForegroundColor Yellow }
            }
            Pause
        }
        "5" {
            $dest = Escolher-Saida-Gravacao
            if ($dest) {
                if (Test-Path $Venv) { & $Venv (Join-Path $Proj "main.py") --gravar $dest }
                else { Write-Host "Rode a opcao [1] primeiro." -ForegroundColor Yellow }
            }
            Pause
        }
        "6" {
            # dashboard minimiza a propria janela do console ao abrir
            # (app.py: WM_DELETE_WINDOW restaura ao fechar)
            if (Test-Path $Venv) {
                Start-Process $Venv -ArgumentList "`"$Proj\main.py`" --dashboard"
            } else {
                Write-Host "Rode a opcao [1] primeiro." -ForegroundColor Yellow
            }
            Pause
        }
        "7" {
            # Sincroniza a pasta raiz do projeto com o GitHub
            & powershell -ExecutionPolicy Bypass -File (Join-Path $Proj "sincronizar_github.ps1")
            Pause
        }
        "8" {
            # Gera publicar_github.exe a partir do fonte .bin (IExpress nativo)
            & powershell -ExecutionPolicy Bypass -File (Join-Path $Proj "restrict\gerar_exe.ps1")
            Pause
        }
        "9" {
            # Aplica patch pendente: o menu injeta o -ExecutionPolicy Bypass
            # (o patch NAO PODE embutir isso nele mesmo: a trava e avaliada
            # pelo PowerShell ANTES da 1a linha do script rodar - ovo e galinha)
            $p = Join-Path $Proj "patch.ps1"
            if (Test-Path $p) {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $p
            } else {
                Write-Host "Nenhum patch.ps1 na raiz do projeto." -ForegroundColor Yellow
            }
            Pause
        }
        "10" {
            # instala o pytesseract SE AUSENTE (checagem por import
            # real); ao sair do script o menu reaparece aqui
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Proj "instalar_pytesseract.ps1")
            Pause
        }
        "0" { $sair = $true }
        default {
            if ($op) {
                Write-Host "Opcao invalida: '$op'" -ForegroundColor Yellow
                Pause
            }
        }
    }
}

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
    "agent\runtime.py" = @'
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
    """Titulo da janela em foco via Win32 nativo (ctypes, instantaneo).

    NAO usar pywinauto aqui (bug real 26/09/2026): o backend 'uia'
    espera o provedor UI Automation da janela em foco responder e
    pode travar por tempo INDEFINIDO - o modo REAL congelava antes
    do primeiro clique (guardrails le o titulo ANTES de cada acao).
    GetForegroundWindow + GetWindowTextW sao chamadas Win32
    sincronas de microssegundos, sem fila de mensagens. Fora do
    Windows retorna '' (o mesmo contrato anterior).
    """
    import sys as _sys
    if _sys.platform != "win32":
        return ""
    try:
        import ctypes
        user32 = ctypes.windll.user32
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return ""
        buf = ctypes.create_unicode_buffer(512)
        user32.GetWindowTextW(hwnd, buf, 512)
        return buf.value
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

'@
    "tests\test_menu_agente.py" = @'
"""
test_menu_agente.py - Verificacao INTEGRAL do menu (agente.ps1).

REGRA DE OURO do usuario (26/09/2026): "TESTAR TODAS AS OPCOES DO
MENU A CADA PATCH (garante que nao gere bug cruzado ou
colateral)". Este modulo automatiza a parte estatica dessa regra:
cada opcao listada no menu tem caso correspondente no switch, os
guards de ambiente existem em TODA opcao que executa o $Venv, os
arquivos chamados existem no projeto, e nenhuma regressao conhecida
voltou (break dentro de switch, saida sem pausa, nao-ASCII).

Limitacao documentada (sandbox sem PowerShell): as checagens sao
ESTATICAS sobre o texto de agente.ps1; a execucao real das
opcoes e feita pelo usuario no Windows. Sandbox 3.11/sem libtk.

Origem (bug real do usuario, 26/09/2026): opcao [1] reportava
"Python 3.12 nao encontrado" quando o venv falhava com
"Errno 13 Permission denied: .venv\\Scripts\\python.exe" (venv em
uso) - o py -3.12 RODOU; o diagnostico era mentiroso. Fix: [a]
checar py --version primeiro, [b] .venv saudavel NAO e recriado
(recriar com ambiente em uso e a causa do Errno 13), [c] .venv
quebrado e apagado com orientacao de desbloqueio, e a saida REAL
do venv e exibida em caso de falha.
"""

import os
import re

BASE = os.path.join(os.path.dirname(__file__), "..")
AGENTE = os.path.join(BASE, "agente.ps1")


def _texto():
    with open(AGENTE, encoding="ascii") as f:
        return f.read()


def _opcoes_do_menu(t):
    """Extrai os numeros [n] listados SOMENTE na funcao Menu (linhas
    'Write-Host "  [n] ...' - 2 espacos apos a aspas; o aviso da
    propria Menu 'opcao [1] primeiro' nao e item de menu)."""
    return sorted(re.findall(r'Write-Host "(?:`n)?  \[(\d+)\] ', t), key=int)


def _casos_do_switch(t):
    """Extrai os numeros dos casos do switch."""
    return sorted(re.findall(r'^\s+"(\d+)" \{', t, re.M), key=int)


def _blocos_opcao(t):
    """Divide o switch em blocos {numero: texto-do-caso}."""
    # casos vao de "1" a "0", nesta ordem, no switch do menu
    partes = re.split(r'^\s+"(\d+)" \{', t, flags=re.M)
    blocos = {}
    for i in range(1, len(partes) - 1, 2):
        blocos[partes[i]] = partes[i + 1]
    return blocos


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731
    t = _texto()

    # === REGRA DE OURO: TODA opcao do menu tem caso no switch ===
    ops_menu = _opcoes_do_menu(t)
    ops_switch = _casos_do_switch(t)
    check("menu lista 11 opcoes (0 a 10)", ops_menu == [str(i) for i in range(11)])
    check("switch tem caso para cada opcao listada (menu == switch)",
          ops_menu == ops_switch and len(ops_switch) == 11)
    blocos = _blocos_opcao(t)
    check("parser de blocos enxergou os 11 casos",
          sorted(blocos.keys(), key=int) == [str(i) for i in range(11)])

    # === REGRA DE OURO: regressoes conhecidas NAO voltaram ===
    check("sem 'break' dentro do switch (gotcha PowerShell: '0 Sair' travava)",
          not re.search(r"^\s*break\s*$", t, re.M))
    check("saida controlada por flag $sair (nao por break)",
          '$sair = $false' in t and '$sair = $true' in t)
    check("opcao invalida tem feedback + Pause (default do switch)",
          "Opcao invalida" in t)
    check("agente.ps1: 100% ASCII (regra dos scripts de console)",
          all(b < 128 for b in open(AGENTE, "rb").read()))

    # === REGRA DE OURO: TUDO que executa $Venv tem guard de existencia ===
    for num, nome in [("2", "testes"), ("3", "dry-run"), ("4", "real"),
                      ("5", "recorder"), ("6", "dashboard")]:
        b = blocos.get(num, "")
        usa = ("$Venv" in b)
        guarda = ("Test-Path $Venv" in b)
        msg = ("opcao [1] primeiro" in b)
        check(f"opcao [{num}] ({nome}): executa venv SO com guard (Test-Path ou aviso)",
              (usa and guarda and msg) or (not usa))

    # === bug real do Errno 13: opcao 1 diagnostico verdadeiro ===
    b1 = blocos.get("1", "")
    check("opcao [1]: checa py -3.12 --version ANTES de culpar o Python",
          "py -3.12 --version" in b1)
    check("opcao [1]: .venv SAUDAVEL nao e recriado (causa do Errno 13)",
          ".venv ja existe - reconfirmando dependencias" in b1)
    check("opcao [1]: .venv QUEBRADO (pasta sem python.exe) e apagado e recriado",
          "Remove-Item -Recurse -Force" in b1 and "sem python.exe" in b1)
    check("opcao [1]: falha de apagar .venv travado orienta desbloqueio",
          "travado" in b1 and "Feche o" in b1)
    check("opcao [1]: saida REAL do venv exibida na falha (2>&1 capturado)",
          "py -3.12 -m venv .venv 2>&1" in b1)
    check("opcao [1]: sucesso verificado por Test-Path $Venv (nao so exit code)",
          "if (Test-Path $Venv)" in b1)
    check("opcao [1]: pip roda SO depois do venv confirmado",
          b1.index("if (Test-Path $Venv)") < b1.index("pip install -r requirements.txt"))
    check("opcao [1]: Tesseract OCR ainda e citado (regressao)",
          "UB-Mannheim/tesseract" in t)
    # === verificacao REAL de dependencias (pedido 26/09/2026: o [1]
    #     nunca CONFIRMOU que pytesseract & cia instalaram de verdade) ===
    check("opcao [1]: funcao Verificar-Deps existe",
          "function Verificar-Deps" in t)
    check("opcao [1]: Verificar-Deps checa as 7 libs (inclui pytesseract)",
          "pytesseract" in t and "pyautogui','pywinauto','pynput','PIL','pytesseract','cv2','jsonschema'" in t)
    check("opcao [1]: verificacao por IMPORT REAL (find_spec, nao so pip exit code)",
          "importlib.util" in t and "find_spec" in t)
    check("opcao [1]: distingue WRAPPER python da ENGINE tesseract.exe (where.exe)",
          "where.exe tesseract" in t and "tesseract.exe e separado" in t)
    check("opcao [1]: Verificar-Deps chamada nos 2 caminhos (venv novo + saudavel)",
          t.count("Verificar-Deps") >= 3)  # 1 def + 2 chamadas

    # === REGRA DE OURO: arquivos chamados por cada opcao EXISTEM ===
    for num, arq in [("2", "tests/run_all.py"), ("3", "main.py"),
                     ("5", "main.py"), ("6", "main.py"),
                     ("7", "sincronizar_github.ps1"),
                     ("8", "restrict/gerar_exe.ps1"),
                     ("10", "instalar_pytesseract.ps1")]:
        existe = os.path.exists(os.path.join(BASE, arq.replace("\\", "/")))
        chamado = arq.split("/")[-1] in blocos.get(num, "")
        check(f"opcao [{num}]: chama '{arq.split('/')[-1]}' e o arquivo existe no projeto",
              existe and chamado)

    check("opcao [9]: so roda patch.ps1 se existir (ovo-e-galinha documentado)",
          'if (Test-Path $p)' in blocos.get("9", ""))
    check("opcao [9]: injeta -ExecutionPolicy Bypass (trava avaliada antes do script)",
          "-NoProfile -ExecutionPolicy Bypass" in blocos.get("9", ""))
    check("opcao [8]: exe e gerado via IExpress com powershell -ExecutionPolicy Bypass",
          "-ExecutionPolicy Bypass" in blocos.get("8", ""))
    check("opcao [4]: modo REAL avisa ESC 3x antes de rodar",
          "ESC 3x" in blocos.get("4", ""))
    check("opcao [4]: SEM confirmacao duplicada no PS (a unica e no main.py)",
          "Continuar?" not in blocos.get("4", "") and
          "O main.py pedira confirmacao" in blocos.get("4", ""))

    # === PAUSA: toda saida visivel termina em pausa (regra anti-flash) ===
    sem_pausa = [n for n, b in blocos.items()
                 if n != "0" and "Pause" not in b and "$Venv" in b]
    check("toda opcao de acao termina com Pause (regra anti-flash)",
          len(sem_pausa) == 0)

    # === opcao [10]: instalar pytesseract SE AUSENTE (pedido do
    #     usuario 26/09/2026) - script separado que volta ao menu ===
    s10 = open(os.path.join(BASE, "instalar_pytesseract.ps1"),
               encoding="ascii").read()
    b10 = blocos.get("10", "")
    check("opcao [10]: chama instalar_pytesseract.ps1 via powershell -File",
          "instalar_pytesseract.ps1" in b10 and "-ExecutionPolicy Bypass" in b10)
    check("opcao [10]: script existe e chama powershell com -NoProfile",
          os.path.exists(os.path.join(BASE, "instalar_pytesseract.ps1")) and
          "-NoProfile -ExecutionPolicy Bypass" in b10)
    check("script [10]: guard de venv (opcao [1] primeiro se faltar)",
          "Test-Path $Venv" in s10 and "opcao [1]" in s10)
    check("script [10]: checa AUSENCIA por import REAL antes de instalar (find_spec)",
          "find_spec('pytesseract')" in s10 and
          s10.index("find_spec('pytesseract')") < s10.index("pip install"))
    check("script [10]: NAO reinstala se ja presente (SE AUSENTE)",
          "JA INSTALADO (import real OK). Nada a fazer." in s10)
    check("script [10]: verifica de NOVO apos instalar (pip exit 0 nao basta)",
          s10.count("find_spec('pytesseract')") >= 2)
    check("script [10]: checa ENGINE tesseract.exe (wrapper != engine)",
          "where.exe tesseract" in s10 and "UB-Mannheim/tesseract" in s10)
    check("script [10]: termina com pausa e avisa que volta ao menu (regra anti-flash)",
          s10.rstrip().endswith("Read-Host \"Pressione ENTER para voltar ao menu\""))
    check("script [10]: saida de erro do guard tambem tem pausa (regra)",
          s10.count("Read-Host") >= 2)
    check("script [10]: 100% ASCII",
          all(b < 128 for b in open(os.path.join(BASE, "instalar_pytesseract.ps1"), "rb").read()))

    # === dashboard: integracao com o minimize do console (v012) ===
    check("opcao [6]: abre dashboard via Start-Process (console minimizado pelo app)",
          "Start-Process $Venv" in blocos.get("6", ""))

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

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "agente.ps1" = "D0382F9C1232F36D96F363FC1147FE0412BFC194243EA873F2E3DE94D254E400"
    "main.py" = "1991941269C6C7F268AD71DB11320A5DEBCE056650FE4C5FF7341962C73E3C0F"
    "agent\runtime.py" = "C592D4C5335D5BBD46245F45587A611175E149B2DE6A7D9EE3089CD75A9672F3"
    "tests\test_menu_agente.py" = "56C5727041C90CAE2AC98236A1E20AB830ACFC62D83F1FF7EDB0369287792C16"
    "tests\test_menu_paths.py" = "BD2BEDF84E63692AF693B7933EDE6D65E6ED7D997045E828ADE21B8C268C1A86"

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
