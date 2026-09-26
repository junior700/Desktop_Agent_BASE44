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
