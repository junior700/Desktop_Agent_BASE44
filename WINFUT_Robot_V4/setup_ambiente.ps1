# ============================================================
#  SETUP DO AMBIENTE — Robô WINFUT (paper trading)
#  Cria o .venv e instala as dependências do requirements.txt
#  Uso: botão direito -> "Executar com PowerShell"
#       ou: powershell -NoProfile -ExecutionPolicy Bypass -File setup_ambiente.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
if (-not $Root) { $Root = Get-Location }
Set-Location $Root

# --- localiza o python ---
$Py = "python"
if (-not (Get-Command $Py)) { $Py = "py" }
if (-not (Get-Command $Py)) {
    Write-Host "ERRO: Python 3.10+ nao encontrado. Instale em python.org" -ForegroundColor Red
    pause; exit 1
}

Write-Host "Python encontrado: $(& $Py --version)" -ForegroundColor Cyan

# --- cria o venv ---
if (Test-Path ".venv") {
    Write-Host ".venv ja existe — reutilizando." -ForegroundColor Yellow
} else {
    Write-Host "Criando ambiente virtual .venv ..." -ForegroundColor Cyan
    & $Py -m venv .venv
}

# --- instala dependências ---
Write-Host "Instalando requirements.txt (pandas, numpy, pyarrow, websocket-client...)" -ForegroundColor Cyan
& ".venv\Scripts\python.exe" -m pip install --upgrade pip
& ".venv\Scripts\python.exe" -m pip install -r requirements.txt

# --- smoke test ---
Write-Host ""
Write-Host "Smoke test das bibliotecas..." -ForegroundColor Cyan
& ".venv\Scripts\python.exe" -c "import pandas, numpy, pyarrow, websocket, matplotlib; print('bibliotecas OK: pandas', pandas.__version__, '| numpy', numpy.__version__)"
Write-Host ""
Write-Host "Ambiente pronto!" -ForegroundColor Green
Write-Host "O dashboard pode usar o venv: edite a linha do PyExe em dashboard_robo.ps1"
Write-Host "para '.venv\Scripts\python.exe', ou ative antes:  .\.venv\Scripts\Activate.ps1"
Write-Host ""
pause
