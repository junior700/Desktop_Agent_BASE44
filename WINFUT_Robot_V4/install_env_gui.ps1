# =====================================================================
#  install_env_gui.ps1 — INSTALADOR NAO-INTERATIVO do ambiente .venv
#  Executado pelo painel grafico (winfut_gui.ps1) em segundo plano.
#  Todo o progresso vai para data\winfut\setup_out.log (o painel mostra).
# =====================================================================
$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
if (-not $Root) { $Root = Get-Location }
Set-Location $Root

$logDir = Join-Path $Root "data\winfut"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "setup_out.log"

function Log([string]$m) {
    $m | Out-File -FilePath $log -Append -Encoding utf8
}

# recomeca o log a cada instalacao
"=== instalacao do ambiente .venv iniciada ===" | Out-File -FilePath $log -Encoding utf8

# --- localiza o python REAL do sistema (ignora o alias falso da Loja) ---
# O Windows traz um "python.exe" falso em WindowsApps que so abre a Loja;
# aqui cada candidato e VALIDADO executando --version de verdade.
$Py = $null
foreach ($c in @("python", "py")) {   # python do PATH primeiro (como nos outros apps)
    $g = Get-Command $c -ErrorAction SilentlyContinue
    if (-not $g) { continue }
    if ($g.Source -like "*WindowsApps*") { continue }   # alias da Loja: pular
    $v = & $c --version 2>&1
    if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3\.(\d+)") { $Py = $c; break }
}
if (-not $Py) {
    # varre os caminhos padrao de instalacao do python.org
    foreach ($gl in @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                      "$env:ProgramFiles\Python3*\python.exe")) {
        foreach ($h in (Get-Item $gl -ErrorAction SilentlyContinue)) {
            $v = & $h.FullName --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3\.(\d+)") { $Py = $h.FullName; break }
        }
        if ($Py) { break }
    }
}
if (-not $Py) {
    Log "ERRO: nao achei um Python real 3.10+ nesta maquina."
    Log "Se voce ja tem Python, abra o menu Iniciar > Python > e verifique a versao;"
    Log "ou me diga o caminho dele que eu configuro na mao."
    exit 1
}
$PyPath = (Get-Command $Py -ErrorAction SilentlyContinue).Source
if (-not $PyPath) { $PyPath = $Py }
$ver = (& $Py --version 2>&1 | Select-Object -First 1)
Log "Python encontrado: $PyPath ($ver)"
$realExe = & $Py -c "import sys; print(sys.executable)" 2>&1
Log "Executavel real: $realExe"
# guarda o caminho para o painel usar depois
$PyPath | Out-File (Join-Path $logDir "python_path.txt") -Encoding ascii

# --- atalho: o python do sistema JA TEM tudo? entao nao precisa de .venv ---
$probe = & $Py -c "import pandas, numpy, pyarrow, websocket, matplotlib" 2>&1
if ($LASTEXITCODE -eq 0) {
    Log "Seu Python do sistema JA TEM todas as dependencias — nada a instalar."
    Log "O painel vai usar ele direto (sem .venv)."
    Log "===INSTALACAO_CONCLUIDA==="
    exit 0
}
Log "Faltam bibliotecas no Python do sistema — vou isolar num .venv (nao baixa Python nenhum)."

# --- cria o venv (se ainda nao existir); se falhar, PLANO B: pip --user ---
$vpy = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $vpy)) { $vpy = Join-Path $Root ".venv/bin/python" }   # Linux
$venvOk = $false
if (Test-Path $vpy) {
    Log ".venv ja existe — reaproveitando."
    $venvOk = $true
} else {
    Log "Criando ambiente virtual .venv ..."
    $out = & $Py -m venv .venv 2>&1
    Log "codigo de retorno do venv: $LASTEXITCODE"
    if ($out) { $out | ForEach-Object { Log $_.ToString() } }
    if (-not (Test-Path $vpy)) { $vpy = Join-Path $Root ".venv/bin/python" }
    if (Test-Path $vpy) {
        $venvOk = $true
    } elseif ($realExe -and (Test-Path $realExe)) {
        Log "Tentando de novo com o executavel real: $realExe"
        $out = & $realExe -m venv .venv 2>&1
        Log "codigo de retorno: $LASTEXITCODE"
        if ($out) { $out | ForEach-Object { Log $_.ToString() } }
        if (-not (Test-Path $vpy)) { $vpy = Join-Path $Root ".venv/bin/python" }
        if (Test-Path $vpy) { $venvOk = $true }
    }
    if (-not $venvOk) {
        Log "nova tentativa: venv --copies (copia os executaveis em vez de apontar) ..."
        $out = & $Py -m venv --copies .venv 2>&1
        Log "codigo de retorno: $LASTEXITCODE"
        if ($out) { $out | ForEach-Object { Log $_.ToString() } }
        if (-not (Test-Path $vpy)) { $vpy = Join-Path $Root ".venv/bin/python" }
        if (Test-Path $vpy) { $venvOk = $true }
    }
}
if (-not $venvOk) {
    # tenta outros Pythons registrados no launcher (py -0p), um a um
    Log "venv falhou com esse Python. Registrados no launcher:"
    $lista = (& py -0p 2>&1)
    $lista | ForEach-Object { Log "  $_" }
    foreach ($m in (("$lista" -join "`n" | Select-String -AllMatches -Pattern '[A-Za-z]:\\[^\s"]+python\.exe').Matches)) {
        $cand = $m.Value
        Log "Tentando venv com: $cand"
        $out = & $cand -m venv .venv 2>&1
        Log "codigo de retorno: $LASTEXITCODE"
        if ($out) { $out | ForEach-Object { Log $_.ToString() } }
        if (-not (Test-Path $vpy)) { $vpy = Join-Path $Root ".venv/bin/python" }
        if (Test-Path $vpy) { $venvOk = $true; $Py = $cand; break }
    }
}
if (-not $venvOk) {
    Log "ERRO: o venv nao foi criado por nenhum Python desta maquina."
    Log "O diagnostico completo esta acima (codigo de retorno + mensagem)."
    Log "Causas mais comuns disso no Windows:"
    Log " 1. ANTIVIRUS removeu o python.exe recem-criado do .venv"
    Log "    (comum no Python 3.14) — Seguranca do Windows > Protecao"
    Log "    contra virus > Historico: veja se ha item em quarentena;"
    Log "    se houver, restaure e exclua a pasta do projeto."
    Log " 2. A pasta do projeto dentro do OneDrive (sincronia trava) —"
    Log "    mova o projeto para fora do OneDrive e rode de novo."
    Log "Copie as linhas acima e me mande que eu corrijo o instalador."
    exit 1
}
Log "venv criado com sucesso: $vpy"

# --- atualiza o pip e instala as dependencias ---
Log "Atualizando pip ..."
& $vpy -m pip install --upgrade pip 2>&1 | ForEach-Object { Log $_.ToString() }
Log "Instalando dependencias (pandas, numpy, etc.) — pode demorar ..."
& $vpy -m pip install -r (Join-Path $Root "requirements.txt") 2>&1 | ForEach-Object { Log $_.ToString() }
if ($LASTEXITCODE -ne 0) {
    Log "ERRO: falha ao instalar as dependencias — verifique a internet."
    exit 1
}

# --- teste final: todas as bibliotecas importam? ---
$probe = & $vpy -c "import pandas, numpy, pyarrow, websocket, matplotlib" 2>&1
if ($LASTEXITCODE -ne 0) {
    Log "ERRO: teste de importacao falhou:"
    Log ($probe | Out-String)
    exit 1
}
Log "Dependencias OK — teste de importacao passou."
Log "===INSTALACAO_CONCLUIDA==="
