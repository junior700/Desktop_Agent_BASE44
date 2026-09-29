# =====================================================================
#  winfut_gui.ps1 — PAINEL GRAFICO do robot WINFUT (paper trading v4)
#  Janela nativa do Windows (WinForms / .NET — nenhuma dependencia extra).
#  Menu no topo + area de texto com o log do robot AO VIVO (auto-tail).
#
#  Como rodar:  start_dashboard.bat  (ou: powershell -NoProfile
#               -ExecutionPolicy Bypass -File winfut_gui.ps1)
#  O robot continua rodando mesmo se fechar esta janela.
# =====================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = "SilentlyContinue"

$Root = $PSScriptRoot
if (-not $Root) { $Root = Get-Location }
Set-Location $Root

# desbloqueia a si proprio (zip baixado da internet pode ser bloqueado)
try { Unblock-File -Path $MyInvocation.MyCommand.Path } catch {}

# --- localiza o python: 1o o venv do projeto, senao o python REAL do sistema ---
# (valida com --version e ignora o alias falso da Loja em WindowsApps)
$venvPy = Join-Path $Root ".venv\Scripts\python.exe"
if (Test-Path $venvPy) { $script:PyExe = $venvPy }
else {
    $script:PyExe = $null
    foreach ($c in @("python", "py")) {   # python do PATH primeiro (como nos outros apps)
        $g2 = Get-Command $c -ErrorAction SilentlyContinue
        if (-not $g2) { continue }
        if ($g2.Source -like "*WindowsApps*") { continue }
        $v = & $c --version 2>&1
        if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3") { $script:PyExe = $c; break }
    }
    # caminho salvo pelo instalador, se houver
    if (-not $script:PyExe) {
        $pp = Join-Path $Root "data\winfut\python_path.txt"
        if (Test-Path $pp) { $cand = (Get-Content $pp -ErrorAction SilentlyContinue | Select-Object -First 1) }
        if ($cand -and (Test-Path $cand)) { $script:PyExe = $cand }
    }
    if (-not $script:PyExe) { $script:PyExe = "python" }   # ultimo recurso
}
$script:VenvPy = $venvPy
$script:installing = $false

$script:BotLog   = Join-Path $Root "data\winfut\bot.log"
$script:SetupOut = Join-Path $Root "data\winfut\setup_out.log"
$BotLog     = $script:BotLog      # compat com outras partes
$SetupOut   = $script:SetupOut
$script:logOffset = 0
$script:autoTail  = $true

# =====================================================================
#  FUNCOES AUXILIARES
# =====================================================================

function Bot-Running {
    $procs = Get-CimInstance Win32_Process -Filter "Name LIKE '%python%'" |
             Where-Object { $_.CommandLine -match "winfut_bot\.py" }
    return [bool]$procs
}

function Append-Log([string]$text) {
    if (-not $text) { return }
    $txt.AppendText(($text -replace "`r?`n", "`r`n"))
    if (-not $txt.Text.EndsWith("`r`n")) { $txt.AppendText("`r`n") }
    $txt.SelectionStart = $txt.Text.Length
    $txt.ScrollToCaret()
}

# le so o que eh NOVO num arquivo de log desde a ultima leitura (tail incremental)
$script:offsets = @{}
function Tail-File([string]$path) {
    try {
        if (-not $path) { return }
        if (-not (Test-Path $path)) { return }
        $fi = Get-Item $path
        if (-not $script:offsets.ContainsKey($path)) {
            # primeira leitura: mostra so o fim do arquivo
            $script:offsets[$path] = [Math]::Max(0, $fi.Length - 4000)
        }
        $off = $script:offsets[$path]
        if ($fi.Length -lt $off) {
            $off = [Math]::Max(0, $fi.Length - 4000)   # arquivo reiniciado
            Append-Log "--- (arquivo de log reiniciado) ---"
        }
        if ($fi.Length -gt $off) {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $fs.Seek($off, 'Begin') | Out-Null
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $new = $sr.ReadToEnd()
            $sr.Close(); $fs.Close()
            # consome exatamente os bytes lidos (UTF-8)
            $script:offsets[$path] = $off + [System.Text.Encoding]::UTF8.GetByteCount($new)
            Append-Log $new
        }
    } catch {}
}

# =====================================================================
#  ACOES DO MENU
# =====================================================================

# roda um comando do bridge (scripts\ps_bridge.py) e joga a saida na tela
function Run-Bridge([string]$cmd, [string]$titulo) {
    Append-Log ("`r`n===== " + $titulo + " =====")
    $out = & $script:PyExe (Join-Path $Root "scripts\ps_bridge.py") $cmd 2>&1
    Append-Log (($out -join "`r`n"))
    Append-Log ""
}

# =====================================================================
#  ACOES DO MENU
# =====================================================================

# inicia um processo SEM janela nenhuma (nem minimizada na barra de tarefas)
function Start-Hidden([string]$exe, [string]$argLine, [string]$wd) {
    # console MINIMIZADO: nao pisca nada na tela, mas o processo tem console
    # de verdade (launcher py / pip / ensurepip falham em processo sem console)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    if ($wd) { $psi.WorkingDirectory = $wd }
    $psi.UseShellExecute = $true
    $psi.WindowStyle = 'Minimized'
    [void][System.Diagnostics.Process]::Start($psi)
}

# checa se o Python tem as dependencias do robot (antes de iniciar)
function Test-Deps {
    $probe = & $script:PyExe -c "import pandas, numpy, pyarrow, websocket, matplotlib" 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Append-Log "ERRO: o Python '$($script:PyExe)' nao tem as dependencias:"
    Append-Log ((($probe | Out-String).Trim()))
    Append-Log "F5 ou Robot > Iniciar corrige isso sozinho."
    return $false
}

$script:autoStart = $false   # ligar o robot assim que a instalacao terminar

function Install-Env {
    if ($script:installing) { Append-Log "Instalacao ja esta em andamento — aguarde."; return }
    Append-Log "=== Instalacao do ambiente (.venv) iniciada ==="
    Append-Log "Baixando pandas, numpy e companhia... pode levar alguns minutos."
    Append-Log "O progresso aparece AQUI. Nao feche o painel."
    $script:installing = $true
    if (Test-Path $SetupOut) { Remove-Item $SetupOut -Force }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Root "install_env_gui.ps1") + '"'
    Start-Hidden "powershell" $argLine $Root
    # apos 6s: se o instalador nao criou o log, algo o bloqueou
    $chk = New-Object System.Windows.Forms.Timer
    $chk.Interval = 6000
    $chk.Add_Tick({ param($sender, $e)
        $sender.Stop()
        if ($script:installing -and -not (Test-Path $script:SetupOut)) {
            $script:installing = $false
            Append-Log "ATENCAO: o instalador oculto nao comecou (antivirus?)..."
            Append-Log "Abrindo o instalador em janela VISIVEL — acompanhe por la."
            Start-Process -FilePath "powershell" `
                -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",(Join-Path $Root "setup_ambiente.ps1") `
                -WorkingDirectory $Root -WindowStyle Minimized
            Append-Log "Ao terminar, feche e reabra o painel para usar o .venv."
        }
    })
    $chk.Start()
}

# cria atalho .lnk na area de trabalho -> chama o PowerShell DIRETO,
# console ja nasce minimizado+oculto: nenhuma janela pisca ao abrir o painel
function Make-Shortcut {
    $desk = [Environment]::GetFolderPath("Desktop")
    $lnk  = Join-Path $desk "Robot WINFUT.lnk"
    $ws   = New-Object -ComObject WScript.Shell
    $sc   = $ws.CreateShortcut($lnk)
    $sc.TargetPath = "powershell.exe"
    $sc.Arguments  = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Root "winfut_gui.ps1") + '"'
    $sc.WorkingDirectory = $Root
    $sc.WindowStyle = 7   # minimizada
    $sc.Description = "Painel do robot WINFUT v4 (paper trading)"
    $sc.Save()
    Append-Log "Atalho criado: $lnk"
    Append-Log "Use ELE para abrir o painel (o .bat pisca porque o CMD abre primeiro)."
}

function Start-Bot {
    if (Bot-Running) { Append-Log "Robot ja esta rodando." ; return }
    Append-Log "Verificando ambiente (Python + venv + bibliotecas)..."
    if (-not (Test-Deps)) {
        Append-Log "Ambiente incompleto — CORRIGINDO AGORA."
        Append-Log "Apagou o .venv? Faltou biblioteca? O instalador conserta tudo."
        Append-Log "Ao terminar, o robot LIGA SOZINHO — nao feche o painel."
        $script:autoStart = $true
        Install-Env
        return
    }
    Append-Log "Ambiente OK. Iniciando robot (loop 120s)..."
    Start-Hidden $script:PyExe "scripts\winfut_bot.py" $Root
    # apos 5s: se o processo morreu, avisa no log (motivo aparece acima)
    $chk = New-Object System.Windows.Forms.Timer
    $chk.Interval = 5000
    $chk.Add_Tick({ param($sender, $e)
        $sender.Stop()
        if (-not (Bot-Running)) {
            Append-Log "ATENCAO: o robot iniciou e morreu em segundos."
            Append-Log "Veja a mensagem de erro acima e rode: Robot > Instalar ambiente."
        }
    })
    $chk.Start()
}

function Stop-Bot {
    $procs = Get-CimInstance Win32_Process -Filter "Name LIKE '%python%'" |
             Where-Object { $_.CommandLine -match "winfut_bot\.py" }
    if ($procs) {
        $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Append-Log "Robot PARADO pelo painel."
    } else {
        Append-Log "Nenhum robot rodando."
    }
}

function Once-Bot {
    if (Bot-Running) { Append-Log "Robot ja esta rodando em loop — use Parar antes."; return }
    if (-not (Test-Deps)) { return }
    Append-Log "Executando UMA iteracao (busca dados + checa sinais)..."
    Start-Hidden $script:PyExe "scripts\winfut_bot.py --once" $Root
}

function Test-Alert {
    Append-Log "Disparando popup de TESTE..."
    # alert_popup.py --test gera o popup OCO de exemplo (simulado)
    Start-Hidden $script:PyExe "scripts\alert_popup.py --test" $Root
}

function Show-Help {
    Append-Log @"
===== COMO USAR =====
1. Menu Robot > Iniciar: o robot roda em segundo plano (janela minimizada).
   Tudo o que ele faz aparece AQUI, nesta area de texto, ao vivo.
2. Sinais/fechamentos abrem popups nativos com os precos no formato OCO
   (COMPRA/VENDA + stop-loss + alvo) para transcrever no Profit.
3. Menu Ver: status, operacoes registradas, posicoes e alertas do paper.
4. Menu Robot > Parar encerra o robot. Fechar ESTA janela NAO para o robot.
5. Se o robot morrer ao iniciar, rode Robot > Instalar ambiente:
   a instalacao roda AQUI no painel e ao terminar o F5 ja funciona.
6. Teclas rapidas: F5 = Iniciar, F6 = Parar.
8. F5 VERIFICA TUDO antes de ligar: venv sumido ou biblioteca
   faltando? Ele reinstala sozinho e liga o robot ao terminar.
7. Menu Robot > Criar atalho: gera o atalho da area de trabalho
   que abre o painel SEM piscar janela nenhuma (use ele no lugar do .bat).
=====================
"@
}

# =====================================================================
#  INTERFACE (WinForms)
# =====================================================================

# --- spinner animado | / - \ quando o robot esta ativo ---
$script:spin     = @("|", "/", "-", "\")
$script:spinIdx  = 0
$script:robotState = $false

# --- estilo: janela e menu MODERNOS (padrao Windows); so a area do log
#     do robot usa o visual CRT (preto + verde fosforescente) ---
$PRETO = [System.Drawing.Color]::Black
$VERDE  = [System.Drawing.Color]::FromArgb(51, 255, 51)      # verde fosforescente
$VERDE2 = [System.Drawing.Color]::FromArgb(120, 255, 120)    # verde claro (hover)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Robot WINFUT — Painel v4 (paper trading)"
$form.Size = New-Object System.Drawing.Size(620, 420)
$form.StartPosition = "CenterScreen"
$form.KeyPreview = $true

# --- area de texto: feedback do robot ao vivo ---
$txt = New-Object System.Windows.Forms.TextBox
$txt.Multiline = $true
$txt.ReadOnly = $true
$txt.ScrollBars = "Vertical"
$txt.WordWrap = $false
$txt.Font = New-Object System.Drawing.Font("Consolas", 11.5)
$txt.BorderStyle = "FixedSingle"
$txt.BackColor = $PRETO
$txt.ForeColor = $VERDE
$txt.Dock = "Fill"
$form.Controls.Add($txt)

# --- barra de status (rodape) ---
$status = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = "Robot: verificando..."
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$status.Items.Add($lblStatus)
$form.Controls.Add($status)

# --- menu no topo ---
function New-Mi([string]$text, [scriptblock]$action) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $mi.Add_Click($action)
    return $mi
}

$menu = New-Object System.Windows.Forms.MenuStrip
$form.Controls.Add($menu)
$form.MainMenuStrip = $menu

$mBot = New-Object System.Windows.Forms.ToolStripMenuItem "&Robot"
[void]$mBot.DropDownItems.Add((New-Mi "Iniciar robot (F5)"          { Start-Bot }))
[void]$mBot.DropDownItems.Add((New-Mi "Parar robot (F6)"           { Stop-Bot }))
[void]$mBot.DropDownItems.Add((New-Mi "Instalar ambiente (.venv)"    { Install-Env }))
[void]$mBot.DropDownItems.Add((New-Mi "Criar atalho na area de trabalho" { Make-Shortcut }))
[void]$mBot.DropDownItems.Add((New-Mi "Executar UMA iteracao"     { Once-Bot }))
[void]$mBot.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$mBot.DropDownItems.Add((New-Mi "Atualizar tela agora"      { Tail-File $BotLog; Run-Bridge "status" "Status" }))
[void]$mBot.DropDownItems.Add((New-Mi "Limpar tela"               { $txt.Clear() }))
[void]$mBot.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$mBot.DropDownItems.Add((New-Mi "Sair do painel"           { $form.Close() }))
[void]$menu.Items.Add($mBot)

$mVer = New-Object System.Windows.Forms.ToolStripMenuItem "&Ver"
[void]$mVer.DropDownItems.Add((New-Mi "Status do robot"             { Run-Bridge "status" "Status" }))
[void]$mVer.DropDownItems.Add((New-Mi "Operacoes registradas"     { Run-Bridge "trades" "Operacoes (paper)" }))
[void]$mVer.DropDownItems.Add((New-Mi "Posicoes abertas"          { Run-Bridge "open"   "Posicoes abertas" }))
[void]$mVer.DropDownItems.Add((New-Mi "Alertas recentes"          { Run-Bridge "alerts" "Alertas recentes" }))
[void]$menu.Items.Add($mVer)

$mAjuda = New-Object System.Windows.Forms.ToolStripMenuItem "&Ajuda"
[void]$mAjuda.DropDownItems.Add((New-Mi "Testar alerta (popup OCO)" { Test-Alert }))
[void]$mAjuda.DropDownItems.Add((New-Mi "Como usar"                 { Show-Help }))
# spinner animado (lado do menu, ponta direita) — gira so com robot ativo
$lblSpin = New-Object System.Windows.Forms.ToolStripLabel
$lblSpin.Text = ""
$lblSpin.Alignment = [System.Windows.Forms.ToolStripItemAlignment]::Right
$lblSpin.ForeColor = [System.Drawing.Color]::Green
$lblSpin.Font = New-Object System.Drawing.Font("Consolas", 12, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add($lblSpin)

[void]$mAjuda.DropDownItems.Add((New-Mi "Sobre"                    { Append-Log "Painel WINFUT v4 — paper trading. Estrategia HILO v2 (compra) + Pernada (short). Sem dinheiro real." }))
[void]$menu.Items.Add($mAjuda)

# --- teclas rapidas ---
$form.Add_KeyDown({
    if ($_.KeyCode -eq "F5") { Start-Bot; $_.Handled = $true }
    if ($_.KeyCode -eq "F6") { Stop-Bot;  $_.Handled = $true }
})

# --- timer: tail do log + estado do robot (a cada 2s) ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    try {
        if ($script:autoTail) {
            Tail-File $script:BotLog
            Tail-File $script:SetupOut
        }
        if ($script:installing -and (Test-Path $script:SetupOut)) {
            $ult = Get-Content $script:SetupOut -Tail 6 -ErrorAction SilentlyContinue
            if ($ult -match "INSTALACAO_CONCLUIDA") {
                $script:installing = $false
                if (Test-Path $script:VenvPy) {
                    $script:PyExe = $script:VenvPy
                    Append-Log "=== Ambiente pronto! Painel agora usa o .venv ==="
                } else {
                    $pp = Join-Path $Root "data\winfut\python_path.txt"
                    if ((Test-Path $pp) -and ($cand = (Get-Content $pp | Select-Object -First 1))) {
                        if (Test-Path $cand) { $script:PyExe = $cand }
                    }
                    Append-Log "=== Ambiente pronto! Usando seu Python do sistema ==="
                }
                if ($script:autoStart) {
                    $script:autoStart = $false
                    Append-Log "Auto-start: ligando o robot..."
                    Start-Bot
                } else {
                    Append-Log "Aperte F5 (ou Robot > Iniciar) para ligar o robot."
                }
            } elseif ($ult -match "ERRO:") {
                $script:installing = $false
                $script:autoStart = $false
                Append-Log "=== Falha na instalacao — veja o erro acima ==="
            }
        }
        $script:robotState = Bot-Running
        if ($script:robotState) {
            $lblStatus.Text = "Robot: ATIVO (loop 120s)"
            $lblStatus.ForeColor = [System.Drawing.Color]::Green
        } else {
            $lblStatus.Text = "Robot: PARADO"
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }
    } catch {
        Append-Log ("ERRO no painel: " + $_.Exception.Message)
    }
})
$timer.Start()

# --- timer do spinner: 4 frames por segundo, so com robot ativo ---
$spinTimer = New-Object System.Windows.Forms.Timer
$spinTimer.Interval = 250
$spinTimer.Add_Tick({
    try {
        if ($script:robotState) {
        $script:spinIdx = ($script:spinIdx + 1) % 4
        $lblSpin.Text = $spin[$script:spinIdx]
    } elseif ($lblSpin.Text -ne "") {
        $lblSpin.Text = ""
    }
    } catch {}
})
$spinTimer.Start()

Append-Log "PAINEL WINFUT v4 — paper trading"
Append-Log "Python: $script:PyExe"
Append-Log "Robot > Iniciar (ou F5) para comecar. Ajuda > Como usar para o resumo."
Append-Log "-----------------------------------------"

# o atalho (.lnk) nasce minimizado (console oculto); o painel se auto-restaura
$form.Add_Shown({
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
})

[void]$form.ShowDialog()
$timer.Stop()
