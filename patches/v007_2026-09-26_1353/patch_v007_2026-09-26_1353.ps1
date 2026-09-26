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

'@
    "tests\test_stack.py" = @'
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

'@
    "tests\run_all.py" = @'
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
    "test_stack.py",
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

'@

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "agent\runtime.py" = "58EF047CA0C951FD2BC0AEA25753FF4F4E826C4879A9BDA4E7B08CA42E006201"
    "tests\test_stack.py" = "F1C6980FCDEA355A039B703FE60309185E92370C6D3E402CB20A3157DD013836"
    "tests\run_all.py" = "A8D3EBC10D9A144766FB39B6C726FF7EF8CD31BF7AFC8D3E333777DD9FEC9C6F"

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
