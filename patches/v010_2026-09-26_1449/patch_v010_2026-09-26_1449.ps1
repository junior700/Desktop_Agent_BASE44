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
    if ($ignAtual -notlike "*token_github*") {
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
    "tests\test_sincronizar_token.py" = @'
"""
test_sincronizar_token.py - Testes do manejo do token_github.txt
no sincronizar_github.ps1.

Motivacao (bug real 26/09/2026, v3.3 do projeto): o script procurava
apenas o nome EXATO token_github.txt. Com o Explorer em
"ocultar extensoes conhecidas", o arquivo real criado pelo usuario
era token_github.txt.txt - o script nao achava e caia na credencial
do Windows (403). Pior: o .gitignore antigo so ignorava
token_github.txt, entao o arquivo com extensao DUPLICADA seria
commitado - vazamento de credencial para o GitHub.

Nao da para executar PowerShell no sandbox de testes; as
checagens sao estaticas sobre o conteudo do .ps1 (mesma
estrategia do test_sed_gerar_exe.py com o SED).
"""

import os
import sys

PS1 = os.path.join(os.path.dirname(__file__), "..",
                   "sincronizar_github.ps1")


def _texto():
    """Le o sincronizar_github.ps1 como ASCII (regra do projeto)."""
    with open(PS1, encoding="ascii") as f:
        return f.read()


def run_all():
    """Roda todas as validacoes; retorna [(nome, ok), ...]."""
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731
    t = _texto()

    # --- auto-cura: busca por PADRAO, nao nome exato ---
    check("token: busca por padrao token_github*.txt",
          '-Filter "token_github*.txt"' in t)
    check("token: Get-ChildItem com -File (so arquivos)",
          "Get-ChildItem" in t and " -File " in t)
    check("token: alternativa exclui o nome exato (nao le 2x)",
          "$_.FullName -ne $TokenFile" in t)
    check("token: nome exato continua sendo a 1a tentativa",
          'Test-Path $TokenFile' in t and
          '$TokenFile = Join-Path $PSScriptRoot "token_github.txt"' in t)
    check("token: aviso mostra o arquivo usado",
          "Token encontrado em: $($alt.FullName)" in t)

    # --- leitura robusta (funcao unificada) ---
    check("token: funcao Ler-Token unificada (1 ponto de leitura)",
          "function Ler-Token([string]$caminho)" in t)
    check("token: trim remove BOM, espacos, quebras e aspas",
          "[char]0xFEFF" in t and chr(34) in t and chr(39) in t)
    # --- .gitignore cobre a extensao duplicada ---
    check("gitignore: lista nova inclui token_github*.txt",
          '"Obsoleto/", "token_github.txt", "token_github*.txt"' in t)
    check("gitignore: .gitignore EXISTENTE recebe o padrao se faltar",
          "-notlike \"*token_github*\"" in t and "AppendAllText" in t)

    # --- guarda de desrastreio (token commitado por engano) ---
    check("seguranca: detecta token rastreado (git ls-files)",
          "git ls-files" in t and '-like "token_github*"' in t)
    check("seguranca: desrastreia com git rm --cached",
          "git rm --cached" in t)
    check("seguranca: orienta REGENERAR o token no GitHub",
          "github.com/settings/tokens" in t)

    # --- regressoes das regras do projeto ---
    check("saida: pausa no fim preservada (Read-Host)",
          "Read-Host" in t)
    dados = open(PS1, "rb").read()
    check("script 100% ASCII (sem byte nao-ASCII)",
          all(b < 128 for b in dados))
    dica = "dir token_github*" in t
    check("mensagem antiga mantida: dica 'dir token_github*'",
          dica)

    return results


if __name__ == "__main__":
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)

'@
    "tests\run_all.py" = @'
"""
run_all.py - Roda TODOS os testes do projeto e reporta o total.
Uso: python tests/run_all.py  (no Windows: .venv\\Scripts\\python tests\\run_all.py)
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTES = [
    "test_guardrails.py",
    "test_control.py",
    "test_interpreter.py",
    "test_recorder.py",
    "test_decision.py",
    "test_smoke.py",
    "test_vision.py",
    "test_sed_gerar_exe.py",
    "test_sincronizar_token.py",
    "test_stack.py",
]


def main():
    total_ok = total = 0
    falhou = []
    for t in TESTES:
        path = os.path.join(HERE, t)
        print(f"\n{'='*60}\n>>> {t}\n{'='*60}")
        r = subprocess.run([sys.executable, path])
        out = _contar(path)
        total_ok += out[0]
        total += out[1]
        if r.returncode != 0 or out[0] != out[1]:
            falhou.append(t)

    print(f"\n{'='*60}")
    print(f"TOTAL GERAL: {total_ok}/{total} testes passaram")
    if falhou:
        print(f"FALHARAM: {', '.join(falhou)}")
        sys.exit(1)
    print("TODOS OS MODULOS OK")
    sys.exit(0)


def _contar(path):
    """Importa o modulo de teste e roda run_all() para contar as checagens."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(path, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    rs = mod.run_all()
    return sum(1 for _, ok in rs if ok), len(rs)


if __name__ == "__main__":
    main()

'@

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "sincronizar_github.ps1" = "A6C038AAEF2CB5CDB3F1B9DBC7797F64F2231EDC9872BE4572E69B25DF3B6FC5"
    "tests\test_sincronizar_token.py" = "C31E1B688DF2C6B9D7278DC3592A00A2E3E7077A0A11A6F1DA5171C9C51DE0A4"
    "tests\run_all.py" = "1F41AEC194DE7B00C1B28ED76DF27BEBA2C37C1BC9055843FD3DBA27656815C9"

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
