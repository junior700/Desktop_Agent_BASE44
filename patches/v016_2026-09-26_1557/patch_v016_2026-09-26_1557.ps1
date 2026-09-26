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
    "test_dashboard_ui.py",
    "test_menu_agente.py",
    "test_menu_paths.py",
    "test_sed_gerar_exe.py",
    "test_sincronizar_token.py",
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

    "main.py" = "77A6F5C1A610E6C1CC9DB92C73A136C6BFED6AA9FC44091B5047EFDBB69B5029"
    "tests\test_menu_paths.py" = "2C4888359A2516F02CF1E53F394080840468F6B142CB2660C0F65EE292283D35"
    "tests\run_all.py" = "EF876ECE9A5B4534C240EFE50F1DFF8E30665F35197F3BE3102B66ECEC678F35"

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
