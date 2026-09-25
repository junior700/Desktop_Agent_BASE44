# ============================================================
# sincronizar_github.ps1 — Sincroniza a PASTA RAIZ onde for
# executado com o repositorio GitHub:
#   https://github.com/junior700/Desktop_Agent_BASE44
#
# Requisitos:
#   - git instalado (https://git-scm.com)
#   - suas credenciais do GitHub (o Windows pede login na
#     primeira vez, via Git Credential Manager)
#
# Uso: coloque este arquivo na PASTA RAIZ do projeto e rode:
#   powershell -ExecutionPolicy Bypass -File .\sincronizar_github.ps1
#
# Seguranca:
#   - NUNCA usa --force: se o GitHub tiver mudancas que voce
#     nao tem, o push e rejeitado e o script avisa.
#   - Cria .gitignore para NAO subir: .venv, __pycache__,
#     agent_audit.db (auditoria local), capturas/, logs/, .env
# ============================================================

# NAO usar $ErrorActionPreference Stop: o git escreve avisos uteis no
# stderr (ex.: LF/CRLF) e o PowerShell 5.1 os transformaria em erro fatal.
$ErrorActionPreference = "Continue"
$Repo = "https://github.com/junior700/Desktop_Agent_BASE44.git"

# pasta raiz = pasta onde este script esta
$Raiz = $PSScriptRoot
if (-not $Raiz) { $Raiz = (Get-Location).Path }
Write-Host "Pasta raiz: $Raiz" -ForegroundColor Cyan
Set-Location $Raiz

# --- git instalado? ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: git nao encontrado. Instale em https://git-scm.com" -ForegroundColor Red
    exit 1
}

# --- .gitignore essencial (nao sobe venv, cache, auditoria, capturas) ---
if (-not (Test-Path ".gitignore")) {
    @(
        ".venv/"
        "venv/"
        "__pycache__/"
        "*.pyc"
        "agent_audit.db"
        "capturas/"
        "logs/"
        "*.log"
        ".env"
        "Obsoleto/"
    ) | Out-File -Encoding utf8 ".gitignore"
    Write-Host ".gitignore criado." -ForegroundColor Green
}

# --- repositorio local existe? senao cria apontando pro GitHub ---
if (-not (Test-Path ".git")) {
    git init | Out-Null
    git config core.autocrlf false
    git branch -M main
    git remote add origin $Repo
    Write-Host "Repositorio local criado (branch main) apontando para o GitHub." -ForegroundColor Green
}
else {
    # repo existente: garante fim de linha sem conversao (evita warnings)
    git config core.autocrlf false
    git remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        git remote add origin $Repo
        Write-Host "Remote origin criado: $Repo" -ForegroundColor Yellow
    }
    else {
        $atual = (git remote get-url origin) -join ""
        if ($atual -ne $Repo) {
            git remote set-url origin $Repo
            Write-Host "Remote origin ajustado para $Repo" -ForegroundColor Yellow
        }
    }
}

# --- acoes ---
function Enviar {
    git add -A
    $pendencias = (git status --porcelain) -join ""
    if ($pendencias) {
        $msg = "sincronizacao " + (Get-Date -Format "yyyy-MM-dd HH:mm")
        git commit -m $msg | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERRO ao criar commit." -ForegroundColor Red
            return
        }
    }
    # ha commits que o GitHub ainda nao tem? (mesmo sem mudancas novas)
    git fetch origin 2>$null
    git rev-parse --verify -q origin/main | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $naFrente = [int]((git rev-list --count origin/main..main) -join "")
    }
    else {
        git rev-parse --verify -q main | Out-Null
        $naFrente = $(if ($LASTEXITCODE -eq 0) { 1 } else { 0 })
    }
    if (-not $pendencias -and $naFrente -eq 0) {
        Write-Host "Nada novo para enviar (local e GitHub iguais)." -ForegroundColor Yellow
        return
    }
    $saida = (git push -u origin main 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        if ($saida -match "403" -or $saida -match "Permission to .* denied") {
            Write-Host "PERMISSAO NEGADA (403): a conta conectada nao tem acesso" -ForegroundColor Red
            Write-Host "de escrita ao repositorio. Veja o nome da conta na mensagem acima." -ForegroundColor Red
            Write-Host ""
            Write-Host "Para trocar a conta do GitHub no Windows:" -ForegroundColor Yellow
            Write-Host "  1) cmdkey /delete:git:https://github.com" -ForegroundColor Yellow
            Write-Host "  2) rode este script de novo (opcao 1): o Windows vai pedir" -ForegroundColor Yellow
            Write-Host "     login; entre com a conta DONA do repositorio" -ForegroundColor Yellow
            Write-Host "  (ou adicione a conta atual como colaborador no site do GitHub)" -ForegroundColor Yellow
        }
        elseif ($saida -match "rejected" -or $saida -match "fetch first") {
            Write-Host "Push REJEITADO: o GitHub tem mudancas que voce nao tem." -ForegroundColor Yellow
            Write-Host "Rode de novo e use a opcao 3 (Sincronizacao completa) primeiro." -ForegroundColor Yellow
        }
        else {
            Write-Host "Push falhou. Detalhes:" -ForegroundColor Red
            Write-Host $saida
        }
        return
    }
    Write-Host "Enviado com sucesso para o GitHub." -ForegroundColor Green
}

function Baixar {
    git fetch origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: sem acesso ao GitHub (verifique internet/credenciais)." -ForegroundColor Red
        return
    }
    # existe a branch main no GitHub?
    git rev-parse --verify -q origin/main | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GitHub ainda nao tem a branch main (nada para baixar). Use a opcao 1 para publicar." -ForegroundColor Yellow
        return
    }
    $temBase = (git merge-base main origin/main 2>$null) -join ""
    if (-not $temBase) {
        # primeira sincronizacao: o GitHub tem so o commit inicial do site;
        # rebase mantem SEUS arquivos na frente de qualquer conflito
        git pull --rebase -X theirs origin main
    }
    else {
        git pull --rebase origin main
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "CONFLITO entre suas mudancas locais e as do GitHub." -ForegroundColor Red
        Write-Host "Resolva manualmente e depois rode a opcao 1:" -ForegroundColor Red
        Write-Host "  git status                     -> ver arquivos em conflito" -ForegroundColor Red
        Write-Host "  (editar os arquivos marcados)" -ForegroundColor Red
        Write-Host "  git add -A" -ForegroundColor Red
        Write-Host "  git rebase --continue" -ForegroundColor Red
        return
    }
    Write-Host "Mudancas do GitHub baixadas (rebase)." -ForegroundColor Green
}

# --- menu ---
Write-Host ""
Write-Host "=== Sincronizar com Desktop_Agent_BASE44 ===" -ForegroundColor Cyan
Write-Host "[1] Enviar mudancas locais   (push)"
Write-Host "[2] Baixar mudancas do GitHub (pull)"
Write-Host "[3] Sincronizacao completa    (baixar + enviar)"
$op = Read-Host "Opcao"

switch ($op) {
    "1" { Enviar }
    "2" { Baixar }
    "3" { Baixar; Enviar }
    default { Write-Host "Opcao invalida." -ForegroundColor Red }
}
Write-Host ""
