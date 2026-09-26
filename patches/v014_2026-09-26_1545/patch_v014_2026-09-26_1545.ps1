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
            $conf = Read-Host "Continuar? [s/N]"
            if ($conf -eq "s") {
                $rot = Escolher-Roteiro
                if ($rot) {
                    if (Test-Path $Venv) { & $Venv (Join-Path $Proj "main.py") $rot --real }
                    else { Write-Host "Rode a opcao [1] primeiro." -ForegroundColor Yellow }
                }
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
    return sorted(re.findall(r'Write-Host "(?:`n)?  \[(\d)\] ', t))


def _casos_do_switch(t):
    """Extrai os numeros dos casos do switch."""
    return sorted(re.findall(r'^\s+"(\d)" \{', t, re.M))


def _blocos_opcao(t):
    """Divide o switch em blocos {numero: texto-do-caso}."""
    # casos vao de "1" a "0", nesta ordem, no switch do menu
    partes = re.split(r'^\s+"(\d)" \{', t, flags=re.M)
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
    check("menu lista 10 opcoes (0 a 9)", ops_menu == [str(i) for i in range(10)])
    check("switch tem caso para cada opcao listada (menu == switch)",
          ops_menu == ops_switch and len(ops_switch) == 10)
    blocos = _blocos_opcao(t)
    check("parser de blocos enxergou os 10 casos",
          sorted(blocos.keys()) == [str(i) for i in range(10)])

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
                     ("8", "restrict/gerar_exe.ps1")]:
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
    check("opcao [4]: modo REAL exige confirmacao explicita [s/N]",
          "Continuar? [s/N]" in blocos.get("4", ""))
    check("opcao [4]: modo REAL avisa ESC 3x antes de rodar",
          "ESC 3x" in blocos.get("4", ""))

    # === PAUSA: toda saida visivel termina em pausa (regra anti-flash) ===
    sem_pausa = [n for n, b in blocos.items()
                 if n != "0" and "Pause" not in b and "$Venv" in b]
    check("toda opcao de acao termina com Pause (regra anti-flash)",
          len(sem_pausa) == 0)

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

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "agente.ps1" = "9181728159357F0066D87F2C3DE3FA616847BCC862D5C0F7306CD0815CB6E36C"
    "tests\test_menu_agente.py" = "291DCB896E23D8AA11D89CBC4FCDDC4ADCD435542E00C18F61285577032A517A"

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
