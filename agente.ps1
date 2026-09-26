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

:loop while ($true) {
    Menu
    $op = Read-Host "Escolha"
    switch ($op) {
        "1" {
            Write-Host "Criando ambiente virtual..."
            Push-Location $Proj
            try {
                py -3.12 -m venv .venv
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "ERRO: Python 3.12 nao encontrado (py -3.12)" -ForegroundColor Red
                } else {
                    & $Venv -m pip install --upgrade pip
                    & $Venv -m pip install -r requirements.txt
                    Write-Host "`nInstalacao concluida. Instale tambem o Tesseract OCR:"
                    Write-Host "  https://github.com/UB-Mannheim/tesseract/wiki"
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
                if ($rot) { & $Venv (Join-Path $Proj "main.py") $rot --real }
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
            Start-Process $Venv -ArgumentList "`"$Proj\main.py`" --dashboard"
        }
        "7" {
            # Sincroniza a pasta raiz do projeto com o GitHub
            & powershell -ExecutionPolicy Bypass -File (Join-Path $Proj "sincronizar_github.ps1")
        }
        "8" {
            # Gera publicar_github.exe a partir do fonte .bin (IExpress nativo)
            & powershell -ExecutionPolicy Bypass -File (Join-Path $Proj "restrict\gerar_exe.ps1")
        }
        "0" { break }
    }
}
