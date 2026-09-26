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

# NAO usar 'break' dentro do switch: no PowerShell o break e consumido
# pelo switch (nao pelo while) - "0 Sair" so redesenhava o menu.
# Saida controlada por flag.
$sair = $false
while (-not $sair) {
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
    "sincronizar_github.ps1" = @'
# ============================================================
# sincronizar_github.ps1 (v4) - Sincroniza a PASTA RAIZ onde for
# executado com o repositorio GitHub:
#   https://github.com/junior700/Desktop_Agent_BASE44
#
# Requisitos:
#   - git instalado (https://git-scm.com)
#   - suas credenciais do GitHub (Windows pede login na 1a vez)
#
# Uso: coloque este arquivo na PASTA RAIZ do projeto e rode:
#   powershell -ExecutionPolicy Bypass -File .\sincronizar_github.ps1
#
# v4 - revisao de manejo git (performance + bug free):
#   - TOKEN NUNCA fica gravado no .git/config: fetch/push usam a
#     URL com token apenas em memoria; o remote origin fica limpo
#     (e se uma versao antiga gravou token, ele e removido agora)
#   - FETCH UNICO por execucao (a opcao 3 nao baixa duas vezes)
#   - opcao 3 so envia se o Baixar terminar bem
#   - .gitignore gravado SEM BOM (BOM quebrava a 1a regra do arquivo)
#   - identidade git local configurada automaticamente se faltar
#     (evita o erro classico "Please tell me who you are")
#   - guard de arvore: conteudo identico ao GitHub = alinha historico
#     com reset --hard sem perder nada (caso real de zip substituido)
#   - Baixar avisa quando ha commits locais pendentes de envio
#   - NUNCA usa --force
# ============================================================

# NAO usar $ErrorActionPreference Stop: o git escreve avisos uteis no
# stderr (LF/CRLF) e o PowerShell 5.1 os transformaria em erro fatal.
$ErrorActionPreference = "Continue"

$script:Repo = "https://github.com/junior700/Desktop_Agent_BASE44.git"

# ------------------------------------------------------------------
# token pessoal (arquivo local, NUNCA versionado). Se existir:
# e usado apenas NA MEMORIA (URL das operacoes), nunca gravado.
# ------------------------------------------------------------------
$TokenFile = Join-Path $PSScriptRoot "token_github.txt"
$script:Token = ""
if (Test-Path $TokenFile) {
    # ReadAllText: sem BOM surpresa; Trim remove espacos/quebras/aspas
    $tk = [IO.File]::ReadAllText($TokenFile).Trim(
        [char]0xFEFF, " ", "`t", "`r", "`n", '"', "'")
    if ($tk) {
        $script:Token = $tk
        Write-Host "Token pessoal detectado (token_github.txt; usado so em memoria)." -ForegroundColor DarkGray
    }
}
# URL das operacoes de rede: com token se houver, senao a limpa
$script:UrlGit = if ($script:Token) {
    "https://x-access-token:$($script:Token)@github.com/junior700/Desktop_Agent_BASE44.git"
} else { $script:Repo }

# pasta raiz = pasta onde este script esta
$script:Raiz = $PSScriptRoot
if (-not $script:Raiz) { $script:Raiz = (Get-Location).Path }
Write-Host "Pasta raiz: $script:Raiz" -ForegroundColor Cyan
Set-Location $script:Raiz

# --- git instalado? ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: git nao encontrado. Instale em https://git-scm.com" -ForegroundColor Red
    # pausa ANTES do exit: sem ela a mensagem pisca e a janela fecha
    Read-Host "Pressione ENTER para fechar" | Out-Null
    exit 1
}

# ------------------------------------------------------------------
# .gitignore essencial - SEM BOM (WriteAllText grava UTF-8 limpo;
# o BOM do Out-File quebrava a primeira regra do arquivo no git)
# ------------------------------------------------------------------
if (-not (Test-Path ".gitignore")) {
    $ign = @(
        ".venv/", "venv/", "__pycache__/", "*.pyc",
        "agent_audit.db", "capturas/", "logs/", "*.log", ".env",
        "Obsoleto/", "token_github.txt"
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $script:Raiz ".gitignore"), $ign)
    Write-Host ".gitignore criado." -ForegroundColor Green
}

# ------------------------------------------------------------------
# repositorio local: cria se faltar; garante identidade e remote LIMPO
# ------------------------------------------------------------------
if (-not (Test-Path ".git")) {
    git init | Out-Null
    git config core.autocrlf false
    git branch -M main
    git remote add origin $script:Repo
    Write-Host "Repositorio local criado (branch main) apontando para o GitHub." -ForegroundColor Green
}
else {
    # fim de linha sem conversao (evita warnings e renormalizacao lenta)
    git config core.autocrlf false
    # MIGRACAO v3->v4: se uma versao antiga gravou token no remote,
    # remove AGORA (token em .git/config e risco de vazamento)
    $urlAtual = (git remote get-url origin 2>$null) -join ""
    if ($urlAtual -match "x-access-token") {
        git remote set-url origin $script:Repo | Out-Null
        Write-Host "AVISO: havia um token gravado no .git/config - removido." -ForegroundColor Yellow
    }
    elseif (-not $urlAtual) {
        git remote add origin $script:Repo | Out-Null
        Write-Host "Remote origin criado." -ForegroundColor Green
    }
}

# identidade local: sem ela o commit falha com erro confuso
$email = (git config user.email) -join ""
if (-not $email) {
    git config user.email "junior700@users.noreply.github.com"
    git config user.name "junior700"
    Write-Host "Identidade git local configurada (junior700 / noreply)." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# FETCH UNICO por execucao (performance: a opcao 3 nao baixa 2x).
# A refspec atualiza refs/remotes/origin/main mesmo usando URL com
# token - o remote config continua limpo.
# ------------------------------------------------------------------
$script:FetchOk = $null
function Garantir-Fetch {
    if ($null -ne $script:FetchOk) { return $script:FetchOk }
    git fetch --quiet $script:UrlGit "+refs/heads/main:refs/remotes/origin/main" 2>$null
    $script:FetchOk = ($LASTEXITCODE -eq 0)
    if (-not $script:FetchOk) {
        Write-Host "ERRO: sem acesso ao GitHub (verifique internet/credenciais)." -ForegroundColor Red
    }
    return $script:FetchOk
}

# garante que token_github.txt esta no .gitignore (mesmo arquivo antigo)
function Proteger-TokenNoGitignore {
    if (Test-Path ".gitignore") {
        $ig = (Get-Content ".gitignore" -Raw) -join ""
        if ($ig -notmatch "token_github\.txt") {
            Add-Content ".gitignore" "token_github.txt"
        }
    }
}

# ==================================================================
# ACAO 1 - ENVIAR (commit local + push, sem --force)
# ==================================================================
function Enviar {
    Proteger-TokenNoGitignore
    git add -A
    $pend = (git status --porcelain) -join ""

    if ($pend) {
        $msg = "sincronizacao " + (Get-Date -Format "yyyy-MM-dd HH:mm")
        git commit -m $msg | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERRO ao criar commit (verifique user.name/user.email)." -ForegroundColor Red
            return $false
        }
    }

    if (-not (Garantir-Fetch)) { return $false }

    git rev-parse --verify -q main | Out-Null
    $temMain = ($LASTEXITCODE -eq 0)
    git rev-parse --verify -q origin/main | Out-Null
    $temRemoto = ($LASTEXITCODE -eq 0)

    $naFrente = 0
    if ($temMain) {
        if ($temRemoto) {
            $naFrente = [int]((git rev-list --count "origin/main..main") -join "")
        }
        else { $naFrente = 1 }   # primeiro publish: sempre ha o que enviar
    }

    if (-not $pend -and $naFrente -eq 0) {
        Write-Host "Nada novo para enviar (local e GitHub iguais)." -ForegroundColor Yellow
        return $true
    }

    # upstream: permite 'git pull/push' direto depois; -u exige remote,
    # e o push aqui usa URL com token (remote fica limpo)
    if ($temMain) {
        $up = (git config branch.main.merge) -join ""
        if (-not $up) {
            git config branch.main.remote origin
            git config branch.main.merge refs/heads/main
        }
    }

    # push pela URL (token em memoria, nada gravado)
    $saida = (git push $script:UrlGit "main:refs/heads/main" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        if ($saida -match "403" -or $saida -match "Permission to .* denied") {
            Write-Host "PERMISSAO NEGADA (403): a conta conectada nao tem acesso" -ForegroundColor Red
            Write-Host "de escrita ao repositorio." -ForegroundColor Red
            Write-Host "Solucao: crie token_github.txt nesta pasta com um token" -ForegroundColor Yellow
            Write-Host "da conta junior700 (github.com/settings/tokens, escopo repo)." -ForegroundColor Yellow
        }
        elseif ($saida -match "rejected" -or $saida -match "fetch first") {
            Write-Host "Push REJEITADO: o GitHub tem mudancas que voce nao tem." -ForegroundColor Yellow
            Write-Host "Rode de novo e use a opcao 3 (Sincronizacao completa)." -ForegroundColor Yellow
        }
        else {
            Write-Host "Push falhou. Detalhes:" -ForegroundColor Red
            Write-Host $saida
        }
        return $false
    }
    Write-Host "Enviado com sucesso para o GitHub." -ForegroundColor Green
    return $true
}

# ==================================================================
# ACAO 2 - BAIXAR (rebase com guarda-corporal, sem perder nada seu)
# ==================================================================
function Baixar {
    # 1) rebase/merge de sessao anterior parado no meio? nao mexe
    if ((Test-Path ".git/rebase-merge") -or (Test-Path ".git/rebase-apply") -or (Test-Path ".git/MERGE_HEAD")) {
        Write-Host ""
        Write-Host "Existe uma rebase/merge INTERROMPIDA no repositorio." -ForegroundColor Red
        Write-Host "Antes de continuar, execute uma destas (na raiz do projeto):" -ForegroundColor Yellow
        Write-Host "  git rebase --abort    (se foi rebase)" -ForegroundColor Yellow
        Write-Host "  git merge --abort     (se foi merge)" -ForegroundColor Yellow
        Write-Host "Depois rode este script de novo." -ForegroundColor Yellow
        return $false
    }

    if (-not (Garantir-Fetch)) { return $false }

    # 2) o GitHub tem a branch main?
    git rev-parse --verify -q origin/main | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GitHub ainda nao tem a branch main (nada para baixar). Use a opcao 1." -ForegroundColor Yellow
        return $false
    }

    # 3) protege token + estagia tudo (autostash manual, evita o erro
    #    "cannot pull with rebase: You have unstaged changes")
    Proteger-TokenNoGitignore
    git add -A

    # 4) GUARD: conteudo da pasta == GitHub? (diff --cached quiet:
    #    exit 0 = arvore do index identica a do origin/main)
    #    Entao adota a historia do GitHub com reset --hard: os
    #    ARQUIVOS sao identicos, nada se perde, e divergencias velhas
    #    de commits sao eliminadas de uma vez.
    git diff --cached --quiet origin/main
    if ($LASTEXITCODE -eq 0) {
        git reset --hard origin/main | Out-Null
        Write-Host "Pasta ja esta identica ao GitHub. Historico alinhado." -ForegroundColor Green
        return $true
    }

    # 5) salva mudancas locais em commit automatico
    $pend = (git status --porcelain) -join ""
    if ($pend) {
        $msg = "ajustes locais " + (Get-Date -Format "yyyy-MM-dd HH:mm")
        git commit -m $msg | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERRO ao salvar mudancas locais em commit." -ForegroundColor Red
            return $false
        }
        Write-Host "Mudancas locais salvas (commit automatico)." -ForegroundColor Green
    }

    # 6) repositorio sem nenhum commit ainda? baixa direto
    git rev-parse --verify -q main | Out-Null
    if ($LASTEXITCODE -ne 0) {
        git reset --hard origin/main | Out-Null
        Write-Host "Projeto baixado do GitHub." -ForegroundColor Green
        return $true
    }

    # 7) quem esta atrasado de quem?
    $atrasado = [int]((git rev-list --count "main..origin/main") -join "")
    $aFrente  = [int]((git rev-list --count "origin/main..main") -join "")
    if ($atrasado -eq 0 -and $aFrente -eq 0) {
        Write-Host "GitHub nao tem nada novo (pasta ja atualizada)." -ForegroundColor Yellow
        return $true
    }
    if ($atrasado -eq 0) {
        Write-Host "GitHub nao tem nada novo. Voce tem commits locais" -ForegroundColor Yellow
        Write-Host "pendentes - use a opcao 1 (Enviar) para publica-los." -ForegroundColor Yellow
        return $true
    }

    # 8) rebase normal, ou "primeira vez" (historias sem parentesco:
    #    SEUS arquivos ganham qualquer conflito)
    $temBase = (git merge-base main origin/main 2>$null) -join ""
    if ($temBase) {
        $saida = (git pull --rebase origin main 2>&1 | Out-String)
    }
    else {
        $saida = (git pull --rebase -X theirs origin main 2>&1 | Out-String)
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        if ($saida -match "CONFLICT") {
            Write-Host "CONFLITO real entre suas edicoes e as do GitHub" -ForegroundColor Red
            Write-Host "na mesma linha de algum arquivo. Para resolver:" -ForegroundColor Red
            Write-Host "  1) git status                        -> ver arquivos em conflito" -ForegroundColor Yellow
            Write-Host "  2) abra cada arquivo e escolha o texto" -ForegroundColor Yellow
            Write-Host "     certo (apague as marcas <<<< ==== >>>>)" -ForegroundColor Yellow
            Write-Host "  3) git add -A ; git rebase --continue" -ForegroundColor Yellow
            Write-Host "  (ou git rebase --abort para voltar tudo ao que era)" -ForegroundColor Yellow
        }
        else {
            Write-Host "Falha ao baixar. Detalhes:" -ForegroundColor Red
            Write-Host $saida
        }
        return $false
    }
    Write-Host "Baixado do GitHub (rebase concluido)." -ForegroundColor Green
    return $true
}

# ==================================================================
# MENU
# ==================================================================
Write-Host ""
Write-Host "=== Sincronizar com github.com/junior700/Desktop_Agent_BASE44 ===" -ForegroundColor Cyan
Write-Host "[1] Enviar mudancas locais (push)"
Write-Host "[2] Baixar mudancas do GitHub (pull)"
Write-Host "[3] Sincronizacao completa (baixar + enviar)"
$op = Read-Host "Opcao"

switch ($op) {
    "1" { Enviar | Out-Null }
    "2" { Baixar | Out-Null }
    # so envia se o baixar terminou bem (evita empurrar por cima de erro)
    "3" { if (Baixar) { Enviar | Out-Null } }
    default { Write-Host "Opcao invalida." -ForegroundColor Red }
}
Write-Host ""

# pausa final: sem isso a janela pisca e fecha antes de ler as mensagens
Write-Host ""
Read-Host "Pressione ENTER para fechar" | Out-Null

'@
    "restrict\gerar_exe.ps1" = @'
# ============================================================
# gerar_exe.ps1 - Transforma os fontes .bin de restrict\ em .exe
#
# COMO FUNCIONA (bug free por construcao):
#   - Ferramenta: IExpress, NATIVO do Windows (System32\iexpress.exe,
#     presente desde o Windows 2000; nada a instalar).
#   - Para cada *.bin em restrict\: copia para uma pasta TEMPORARIA
#     com a extensao .bat restaurada, gera o .SED e roda:
#         iexpress.exe /N /Q /M <arquivo>.SED
#   - O .bat real so existe no %TEMP% durante o build; ao final a
#     pasta temporaria inteira e apagada. Fonte e zip ficam limpos.
#   - O .exe gerado sai na RAIZ do projeto (um nivel acima de
#     restrict\): ex. publicar_github.exe.
#
# USO (na raiz do projeto, ou pela opcao [8] do agente.ps1):
#   powershell -ExecutionPolicy Bypass -File .\restrict\gerar_exe.ps1
#
# NOTA HONESTA (antivirus): o .exe gerado NAO e assinado; o
# SmartScreen/antivirus pode mostrar "app nao reconhecido" na
# primeira vez ("Mais informacoes" -> "Executar assim mesmo").
# Se isso incomodar, o .ps1 de sincronizacao e a alternativa
# transparente - o que o .exe faz e exatamente o que o .bin diz.
# ============================================================

$ErrorActionPreference = "Stop"

$Restrict = $PSScriptRoot                      # ...projeto\restrict
$Raiz     = Split-Path $Restrict -Parent       # ...projeto

# --- IExpress existe? (nativo do Windows) ---
$IExpress = Join-Path $env:WINDIR "System32\iexpress.exe"
if (-not (Test-Path $IExpress)) {
    $IExpress = Join-Path $env:WINDIR "SysWOW64\iexpress.exe"
}
if (-not (Test-Path $IExpress)) {
    Write-Host "ERRO: iexpress.exe nao encontrado (nao deveria acontecer" -ForegroundColor Red
    Write-Host "no Windows 10/11 - verifique $env:WINDIR\System32)." -ForegroundColor Red
    Read-Host "Pressione ENTER para fechar" | Out-Null
    exit 1
}

# --- fontes .bin da pasta restrict ---
$fontes = @(Get-ChildItem -Path $Restrict -Filter "*.bin" -File)
if ($fontes.Count -eq 0) {
    Write-Host "Nenhum fonte .bin encontrado em: $Restrict" -ForegroundColor Yellow
    Read-Host "Pressione ENTER para fechar" | Out-Null
    exit 0
}

Write-Host ""
Write-Host "=== Gerando executaveis (IExpress nativo) ===" -ForegroundColor Cyan
Write-Host "Fontes em : $Restrict"
Write-Host "Saida em  : $Raiz" 
Write-Host ""

$gerados = 0
foreach ($f in $fontes) {
    $nome   = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $destExe = Join-Path $Raiz "$nome.exe"

    # pasta TEMPORARIA do build (o .bat so vive aqui, e morre aqui)
    $suf = [IO.Path]::GetRandomFileName() -replace "\.", ""
    $tmp = Join-Path $env:TEMP ("gerar_exe_{0}_{1}" -f $nome, $suf)
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $batTmp = Join-Path $tmp "$nome.bat"
    Copy-Item $f.FullName $batTmp

    # SED: diretiva do IExpress (formato canonico do assistente)
    # refs: docs Microsoft IExpress; SED sample Ut Video (doom9);
    # ps2exe-iexpress (github.com/Ramikan/Shelling)
    $sed = Join-Path $tmp "$nome.SED"
    $sedConteudo = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=0
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInst=%AdminQuietInst%
UserInstCmd=%UserInstCmd%
SourceFiles=%SourceFiles%
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
FriendlyName=$nome
TargetName=$destExe
AppLaunched=$nome.bat
PostInstallCmd=<None>
AdminQuietInst=
UserInstCmd=
FILE0="$nome.bat"
[SourceFiles]
SourceFiles0=$tmp\
[SourceFiles0]
%FILE0%="$nome.bat"
"@
    [IO.File]::WriteAllText($sed, $sedConteudo, [Text.Encoding]::ASCII)

    # build silencioso: /N sem assistente, /Q quiet, /M a partir do SED
    & $IExpress "/N" "/Q" "/M" $sed | Out-Null
    $erro = ($LASTEXITCODE -ne 0)

    if (-not $erro -and (Test-Path $destExe)) {
        Write-Host "[OK] $($f.Name) -> $nome.exe" -ForegroundColor Green
        $gerados++
    }
    else {
        Write-Host "[ERRO] $($f.Name): iexpress falhou (codigo $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "       SED preservado para inspecao: $sed" -ForegroundColor Yellow
    }

    # limpeza do TEMP (mantida em caso de erro, para debug do SED)
    if (-not $erro) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($gerados -gt 0) {
    Write-Host ("{0} executavel(is) gerado(s) na raiz do projeto." -f $gerados) -ForegroundColor Green
    Write-Host "Primeira execucao pode mostrar o aviso do SmartScreen" -ForegroundColor Yellow
    Write-Host "(nao assinado): 'Mais informacoes' -> 'Executar assim mesmo'." -ForegroundColor Yellow
}
Read-Host "Pressione ENTER para fechar" | Out-Null
exit 0

'@

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "agente.ps1" = "B4406E09763C6B1BE25098F7C473A3641EBCBD0BFA4F89D5AA0E6AD54377070A"
    "sincronizar_github.ps1" = "C8199CD03819E37248FFE6608DA1DA6C6552195DEA92FFE4AAF94B2922EB3158"
    "restrict\gerar_exe.ps1" = "FDB79692F1E74A3D07E94729AF920E478E37BF8E9072406876473AD624B2EB8C"

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
