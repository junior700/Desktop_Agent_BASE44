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
function Ler-Token([string]$caminho) {
    # ReadAllText: sem BOM surpresa; Trim remove espacos/quebras/aspas
    return [IO.File]::ReadAllText($caminho).Trim(
        [char]0xFEFF, " ", "`t", "`r", "`n", '"', "'")
}
if (Test-Path $TokenFile) {
    $tk = Ler-Token $TokenFile
    if ($tk) {
        $script:Token = $tk
        Write-Host "Token pessoal detectado ($TokenFile; usado so em memoria)." -ForegroundColor DarkGray
    } else {
        Write-Host "AVISO: $TokenFile existe mas esta VAZIO. Operacoes de rede" -ForegroundColor Yellow
        Write-Host "vao usar a credencial do Windows (pode dar 403)." -ForegroundColor Yellow
    }
}
if (-not $script:Token) {
    # AUTO-CURAR (bug real 26/09/2026): Explorer com 'ocultar extensoes
    # conhecidas' cria token_github.txt.txt que APARECE como
    # token_github.txt. Busca por PADRAO, nao por nome exato.
    $alternativos = Get-ChildItem -Path $PSScriptRoot `
        -Filter "token_github*.txt" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $TokenFile } | Sort-Object Name
    foreach ($alt in $alternativos) {
        $tk = Ler-Token $alt.FullName
        if ($tk) {
            $script:Token = $tk
            Write-Host "Token encontrado em: $($alt.FullName)" -ForegroundColor Green
            Write-Host "(nome com extensao duplicada? renomeie para token_github.txt)" -ForegroundColor Yellow
            break
        }
    }
}
if (-not $script:Token) {
    # avisa JA AQUI (nao so depois do 403) - poupa 1 tentativa perdida
    Write-Host "Token nao encontrado em: $TokenFile" -ForegroundColor Yellow
    Write-Host "Operacoes de rede vao usar a credencial do Windows (pode dar 403)." -ForegroundColor Yellow
    Write-Host "ARMADILHA COMUM: extensoes ocultas do Windows Explorer escondem" -ForegroundColor Yellow
    Write-Host "so a ULTIMA extensao. Se voce criou o arquivo e ele aparece como" -ForegroundColor Yellow
    Write-Host "'token_github.txt' no Explorer, o nome real pode ser" -ForegroundColor Yellow
    Write-Host "'token_github.txt.txt'. Confira no PowerShell, nesta pasta:" -ForegroundColor Yellow
    Write-Host "    dir token_github*" -ForegroundColor Yellow
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
        "Obsoleto/", "token_github.txt", "token_github*.txt"
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $script:Raiz ".gitignore"), $ign)
    Write-Host ".gitignore criado." -ForegroundColor Green
}
else {
    # .gitignore antigo pode nao cobrir token com extensao duplicada
    # (token_github.txt.txt seria commitado = vazamento de credencial)
    $ignAtual = [IO.File]::ReadAllText((Join-Path $script:Raiz ".gitignore"))
    # BUG v010: a checagem era '*token_github*' (frouxa) - o .gitignore
    # antigo com 'token_github.txt' satisfazia e o PADRAO nunca entrava,
    # deixando o token_github.txt.txt ser commitado. Checar o padrao LITERAL.
    if ($ignAtual -notlike "*token_github*.txt*") {
        [IO.File]::AppendAllText((Join-Path $script:Raiz ".gitignore"),
            [Environment]::NewLine + "token_github*.txt")
        Write-Host ".gitignore: adicionado padrao do token (seguranca)." -ForegroundColor Green
    }
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

# SEGURANCA: se um arquivo de token foi rastreado pelo git
# (commit anterior com extensao duplicada, p.ex.), tira do indice
# AGORA. Token em repositorio e vazamento de credencial.
$tokenRastreado = @(git ls-files | Where-Object { $_ -like "token_github*" })
if ($tokenRastreado.Count -gt 0) {
    git rm --cached $tokenRastreado | Out-Null
    Write-Host "AVISO: arquivo de token estava RASTREADO pelo git -" -ForegroundColor Yellow
    Write-Host "removido do indice ($($tokenRastreado -join ', '))." -ForegroundColor Yellow
    Write-Host "Se ele ja foi enviado ao GitHub em commit anterior," -ForegroundColor Yellow
    Write-Host "REGENERE o token em github.com/settings/tokens." -ForegroundColor Yellow
}
$tokenNoHistorico = @(git log --all --oneline -- "token_github*" 2>$null)
if ($tokenNoHistorico.Count -gt 0) {
    Write-Host "AVISO GRAVE: o token aparece em COMMITS do historico local" -ForegroundColor Red
    Write-Host "(commit automatico antigo, p.ex.). Se um push levar esses" -ForegroundColor Red
    Write-Host "commits, o token fica PUBLICO no GitHub." -ForegroundColor Red
    Write-Host "Apos sincronizar, REGENERE o PAT em github.com/settings/tokens" -ForegroundColor Yellow
    Write-Host "e salve o novo no token_github.txt." -ForegroundColor Yellow
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
    $saidaFetch = (git fetch $script:UrlGit `
        "+refs/heads/main:refs/remotes/origin/main" 2>&1 | Out-String)
    $script:FetchOk = ($LASTEXITCODE -eq 0)
    if (-not $script:FetchOk) {
        Write-Host "ERRO: sem acesso ao GitHub. Motivo:" -ForegroundColor Red
        # sanitiza: nunca mostra o token que vai na URL
        Write-Host (($saidaFetch -replace "x-access-token:[^@]*@",
                      "x-access-token:***@").Trim())
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

    # INTEGRACAO (bug real 26/09/2026: mensagens circulares "use a
    # opcao 1"/"use a opcao 3" - a opcao 1 NUNCA integrava o remoto).
    # Fluxo padrao documentado do GitHub para non-fast-forward:
    # fetch -> rebase -> push. Sem isso, historico divergente
    # rejeita o push para sempre (a razao do loop do usuario).
    $atrasado = 0
    if ($temMain -and $temRemoto) {
        $atrasado = [int]((git rev-list --count "main..origin/main") -join "")
    }
    if ($atrasado -gt 0) {
        Write-Host "GitHub tem $atrasado commit(s) novo(s) - integrando antes do push..." -ForegroundColor Cyan
        $saidaReb = (git rebase origin/main 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            if ($saidaReb -match "CONFLICT") {
                git rebase --abort | Out-Null
                Write-Host "CONFLITO ao integrar. Opcoes:" -ForegroundColor Red
                Write-Host "  - Opcao 4 (a pasta local MANDA, sobrescreve o GitHub)" -ForegroundColor Yellow
                Write-Host "  - Opcao 5 (o GitHub MANDA, a pasta fica igual ao remoto)" -ForegroundColor Yellow
            }
            else {
                Write-Host "Falha ao integrar. Detalhes:" -ForegroundColor Red
                Write-Host (($saidaReb -replace "x-access-token:[^@]*@",
                              "x-access-token:***@").Trim())
            }
            return $false
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
            Write-Host "Use a opcao 3 (Sincronizacao completa) ou, se quiser que a" -ForegroundColor Yellow
            Write-Host "PASTA LOCAL venca, a opcao 4 (forca segura)." -ForegroundColor Yellow
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
# ACAO 4 - FORCAR (pasta local MANDA; --force-with-lease, documentado
# como mais seguro que --force: recusa se o remoto mudou desde o
# ultimo fetch conhecido, protegendo contra apagar trabalho alheio)
# ==================================================================
function Forcar {
    Proteger-TokenNoGitignore
    git add -A
    $pend = (git status --porcelain) -join ""
    if ($pend) {
        $msg = "sincronizacao forcada " + (Get-Date -Format "yyyy-MM-dd HH:mm")
        git commit -m $msg | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERRO ao criar commit." -ForegroundColor Red
            return $false
        }
    }
    if (-not (Garantir-Fetch)) { return $false }
    $saida = (git push --force-with-lease $script:UrlGit `
        "main:refs/heads/main" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Forca recusada. Detalhes (sanitizado):" -ForegroundColor Red
        Write-Host (($saida -replace "x-access-token:[^@]*@",
                      "x-access-token:***@").Trim())
        Write-Host "(--force-with-lease recusa se o GitHub mudou apos o fetch;" -ForegroundColor Yellow
        Write-Host " rode de novo - o fetch desta execucao atualiza a base)" -ForegroundColor Yellow
        return $false
    }
    Write-Host "GitHub sobrescrito: agora esta IGUAL a pasta local." -ForegroundColor Green
    return $true
}

# ==================================================================
# ACAO 5 - RESET (o GitHub MANDA; padrao 'git reset --hard
# origin/main': a pasta local fica EXATAMENTE igual ao remoto.
# Arquivos nao rastreados/ignorados (token, capturas, .venv) ficam)
# ==================================================================
function Resetar {
    if (-not (Garantir-Fetch)) { return $false }
    git rev-parse --verify -q origin/main | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GitHub ainda nao tem a branch main." -ForegroundColor Yellow
        return $false
    }
    Write-Host "ATENCAO: commits e ajustes locais NAO publicados serao" -ForegroundColor Yellow
    Write-Host "DESCARTADOS; a pasta ficara igual ao GitHub." -ForegroundColor Yellow
    Write-Host "Arquivos ignorados (token, capturas, .venv) NAO sao tocados." -ForegroundColor Cyan
    $conf = Read-Host "Confirmar reset? [s/N]"
    if ($conf -ne "s") {
        Write-Host "Cancelado." -ForegroundColor Yellow
        return $false
    }
    git reset --hard origin/main | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Falha no reset." -ForegroundColor Red
        return $false
    }
    Write-Host "Pasta local agora esta IGUAL ao GitHub." -ForegroundColor Green
    return $true
}

# ==================================================================
# MENU
# ==================================================================
Write-Host ""
Write-Host "=== Sincronizar com github.com/junior700/Desktop_Agent_BASE44 ===" -ForegroundColor Cyan
Write-Host "[1] Enviar mudancas locais (commit + integracao + push)"
Write-Host "[2] Baixar mudancas do GitHub (pull)"
Write-Host "[3] Sincronizacao completa (baixar + enviar)"
Write-Host "[4] FORCAR: pasta local MANDA (forca segura no GitHub)"
Write-Host "[5] RESET: GitHub MANDA (pasta fica igual ao remoto)"
$op = Read-Host "Opcao"

switch ($op) {
    "1" { Enviar | Out-Null }
    "2" { Baixar | Out-Null }
    # so envia se o baixar terminou bem (evita empurrar por cima de erro)
    "3" { if (Baixar) { Enviar | Out-Null } }
    "4" { Forcar | Out-Null }
    "5" { Resetar | Out-Null }
    default { Write-Host "Opcao invalida." -ForegroundColor Red }
}
Write-Host ""

# pausa final: sem isso a janela pisca e fecha antes de ler as mensagens
Write-Host ""
Read-Host "Pressione ENTER para fechar" | Out-Null
