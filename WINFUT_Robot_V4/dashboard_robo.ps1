# ============================================================
#  DASHBOARD DE CONTROLE — Robot WINFUT (paper trading)
#  Uso: powershell -NoProfile -ExecutionPolicy Bypass -File dashboard_robo.ps1
#  Ou: clique com o botão direito -> "Executar com PowerShell"
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
Write-Host "Carregando painel WINFUT... (PowerShell $($PSVersionTable.PSVersion))" -ForegroundColor Cyan
$Root  = $PSScriptRoot
if (-not $Root) { $Root = Get-Location }
Set-Location $Root

# --- desbloqueia arquivos vindos de zip baixado da internet (Mark of the Web) ---
# PowerShell pode bloquear silenciosamente scripts "da zona de internet".
$esteArquivo = $MyInvocation.MyCommand.Path
if ($esteArquivo -and (Get-Command Unblock-File)) {
    try { Unblock-File -Path $esteArquivo -ErrorAction Stop } catch {}
}

# --- localiza o python: 1o o venv do projeto, depois python/py do sistema ---
$venvPy = Join-Path $Root ".venv\Scripts\python.exe"
if (Test-Path $venvPy) { $script:PyExe = $venvPy }
else {
    $script:PyExe = "python"
    if (-not (Get-Command $script:PyExe)) { $script:PyExe = "py" }
}
if (-not (Get-Command $script:PyExe)) {
    Write-Host "ERRO: python nao encontrado no PATH. Instale o Python 3.10+." -ForegroundColor Red
    pause; exit 1
}

function Get-BotProcess {
    # processo do robot: qualquer python executando winfut_bot.py
    Get-CimInstance Win32_Process -Filter "Name LIKE '%python%'" |
        Where-Object { $_.CommandLine -like "*winfut_bot.py*" }
}

function Show-Status {
    Clear-Host
    Write-Host "=============== STATUS DO ROBO WINFUT ===============" -ForegroundColor Cyan
    $p = Get-BotProcess
    if ($p) {
        Write-Host "  Processo .....: ATIVO (PID $($p.ProcessId))" -ForegroundColor Green
    } else {
        Write-Host "  Processo .....: PARADO" -ForegroundColor Yellow
    }
    Write-Host "  Pasta .........: $Root"
    $log = Join-Path $Root "data\winfut\bot.log"
    if (Test-Path $log) {
        Write-Host "  Ultimas linhas do log:" -ForegroundColor Cyan
        Get-Content $log -Tail 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "  (log ainda nao existe - o robot nao rodou nesta pasta)" -ForegroundColor DarkGray
    }
    Write-Host ""
    & $script:PyExe scripts\ps_bridge.py status
    & $script:PyExe scripts\ps_bridge.py open
    Write-Host ""
    pause
}

function Start-Bot {
    $p = Get-BotProcess
    if ($p) { Write-Host "O robot JA esta rodando (PID $($p.ProcessId))." -ForegroundColor Yellow; pause; return }
    Write-Host "Iniciando robot (loop 120s, janela minimizada)..." -ForegroundColor Cyan
    Start-Process -FilePath $script:PyExe `
        -ArgumentList "scripts\winfut_bot.py", "--loop" `
        -WorkingDirectory $Root -WindowStyle Minimized
    Start-Sleep -Seconds 3
    $p = Get-BotProcess
    if ($p) { Write-Host "Robot ATIVO (PID $($p.ProcessId)). Log: data\winfut\bot.log" -ForegroundColor Green }
    else    { Write-Host "Nao confirmou o processo - verifique o log de erros." -ForegroundColor Red }
    pause
}

function Stop-Bot {
    $p = Get-BotProcess
    if (-not $p) { Write-Host "O robot nao esta rodando." -ForegroundColor Yellow; pause; return }
    $p | ForEach-Object {
        Write-Host "Encerrando PID $($_.ProcessId)..." -ForegroundColor Yellow
        Stop-Process -Id $_.ProcessId -Force
    }
    Start-Sleep -Seconds 1
    if (-not (Get-BotProcess)) { Write-Host "Robot PARADO." -ForegroundColor Green }
    pause
}

function Show-LiveLog {
    $log = Join-Path $Root "data\winfut\bot.log"
    if (-not (Test-Path $log)) { Write-Host "(log ainda nao existe)" -ForegroundColor DarkGray; pause; return }
    Clear-Host
    Write-Host "=== LOG AO VIVO (Ctrl+C para sair) ===" -ForegroundColor Cyan
    Get-Content $log -Tail 40 -Wait
}

function Run-Once {
    Write-Host "Executando UMA iteracao do robot (fetch + sinais + gestao)..." -ForegroundColor Cyan
    & $script:PyExe scripts\winfut_bot.py --once
    Write-Host ""
    pause
}

function Update-Data {
    Write-Host "Atualizando bases WIN (5m, 15m, 1D) via TradingView..." -ForegroundColor Cyan
    foreach ($tf in @("5m", "15m", "1D")) {
        & $script:PyExe scripts\tv_ws_fetch.py $tf win
    }
    Write-Host "Bases atualizadas (a base 10m e derivada do 5m na proxima leitura)." -ForegroundColor Green
    pause
}

function Install-Env {
    Write-Host "Instalando ambiente (.venv + requirements.txt)..." -ForegroundColor Cyan
    $sysPy = "python"
    if (-not (Get-Command $sysPy)) { $sysPy = "py" }
    if (-not (Get-Command $sysPy)) {
        Write-Host "ERRO: Python 3.10+ nao encontrado no PATH." -ForegroundColor Red
        pause; return
    }
    if (-not (Test-Path ".venv")) {
        Write-Host "Criando .venv ..." -ForegroundColor Cyan
        & $sysPy -m venv .venv
    } else {
        Write-Host ".venv ja existe — reutilizando." -ForegroundColor Yellow
    }
    & ".venv\Scripts\python.exe" -m pip install --upgrade pip
    & ".venv\Scripts\python.exe" -m pip install -r requirements.txt
    Write-Host ""
    & ".venv\Scripts\python.exe" -c "import pandas, numpy, pyarrow, websocket, matplotlib; print('bibliotecas OK')"
    Write-Host "Ambiente pronto — o painel agora usa o .venv automaticamente." -ForegroundColor Green
    # aponta o painel para o python do venv a partir de agora
    $script:PyExe = Join-Path $Root ".venv\Scripts\python.exe"
    pause
}

function Test-Alert {
    Write-Host "Disparando popup de TESTE (simulado, nao e operacao real)..." -ForegroundColor Cyan
    $titulo = "TESTE - SINAL COMPRA - Robot WINFUT (paper)"
    $msg = "TESTE DE ALERTA - simulado, nao e operacao real.`n`n" +
           "ACAO: COMPRA WINFUT @ 183100`n`n" +
           "OCO - VENDAS de protecao (colocar no Profit):`n" +
           "   * VENDA stop-loss @ 182500`n" +
           "   * VENDA alvo @ 184750  (M50 184600 + 150)`n`n" +
           "Se esta janela apareceu (com som), os alertas estao OK."
    & $script:PyExe scripts\alert_popup.py $titulo $msg
    Write-Host ""
    Write-Host "Se a janela nao apareceu, me avise o que aconteceu." -ForegroundColor Yellow
    pause
}

# ---------------- menu principal ----------------
try {
while ($true) {
    Clear-Host
    $p = Get-BotProcess
    $estado = if ($p) { "ATIVO" } else { "parado" }
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   PAINEL DO ROBO WINFUT - paper trading (v4)" -ForegroundColor Cyan
    Write-Host "   Estado atual: $estado" -ForegroundColor $(if ($p) {"Green"} else {"Yellow"})
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  [1] Status do robot"
    Write-Host "  [2] INICIAR robot (loop 120s)"
    Write-Host "  [3] PARAR robot"
    Write-Host "  [4] Log ao vivo (Ctrl+C sai)"
    Write-Host "  [5] Operacoes registradas (paper)"
    Write-Host "  [6] Posicoes abertas"
    Write-Host "  [7] Resumo do paper (win/pts/R`$)"
    Write-Host "  [8] Alertas recentes"
    Write-Host "  [9] Executar UMA iteracao agora"
    Write-Host "  [T] Teste de alerta (popup)"
    Write-Host "  [I] Instalar ambiente (.venv)"
    Write-Host "  [U] Atualizar dados WIN"
    Write-Host "  [0] Sair"
    Write-Host ""
    $op = Read-Host "Escolha uma opcao"
    switch ($op) {
        "1" { Show-Status }
        "2" { Start-Bot }
        "3" { Stop-Bot }
        "4" { Show-LiveLog }
        "5" { Clear-Host; & $script:PyExe scripts\ps_bridge.py trades; Write-Host ""; pause }
        "6" { Clear-Host; & $script:PyExe scripts\ps_bridge.py open;  Write-Host ""; pause }
        "7" { Clear-Host; & $script:PyExe scripts\ps_bridge.py status; Write-Host ""; pause }
        "8" { Clear-Host; & $script:PyExe scripts\ps_bridge.py alerts; Write-Host ""; pause }
        "9" { Run-Once }
        "T" { Test-Alert }
        "I" { Install-Env }
        "U" { Update-Data }
        "0" { exit 0 }
    }
}
} catch {
    Write-Host ""
    Write-Host "ERRO INESPERADO: $_" -ForegroundColor Red
    Write-Host "Em: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Read-Host "Pressione Enter para fechar"
}