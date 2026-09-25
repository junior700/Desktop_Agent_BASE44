@echo off
setlocal EnableDelayedExpansion

REM ============================================================
REM publicar_github.bat - Git Add/Commit/Push Automatico
REM Base: script do usuario, com 3 correcoes:
REM   1) raiz = pasta onde ESTE arquivo esta (nao dois niveis acima)
REM   2) baixa novidades do GitHub ANTES de empurrar (evita push rejeitado)
REM   3) usa token_github.txt (opcional) para autenticar no push
REM
REM Coloque este .bat na RAIZ do projeto (ao lado do main.py).
REM Para autenticar sem depender do navegador, crie
REM token_github.txt na mesma pasta com o PAT dentro (uma linha).
REM ============================================================

cd /d "%~dp0"
echo ========================================
echo   Git Add/Commit/Push Automatico
echo ========================================
echo.
echo Repositorio: %CD%
echo.

where git >nul 2>&1
if errorlevel 1 (
    echo ERRO: git nao encontrado. Instale em https://git-scm.com
    pause
    exit /b 1
)

REM --- .gitignore essencial (nunca versiona token/venv/auditoria) ---
if not exist .gitignore (
    echo Criando .gitignore...
    (
        echo .venv/
        echo venv/
        echo env/
        echo __pycache__/
        echo *.pyc
        echo *.log
        echo .tmp.driveupload/
        echo .cache/
        echo node_modules/
        echo .DS_Store
        echo Thumbs.db
        echo desktop.ini
        echo *.tmp
        echo *.temp
        echo agent_audit.db
        echo capturas/
        echo Obsoleto/
        echo token_github.txt
    ) > .gitignore
)
findstr /C:"token_github.txt" .gitignore >nul 2>&1
if errorlevel 1 echo token_github.txt>> .gitignore

REM --- repositorio local existe? ---
if not exist .git (
    git init >nul 2>&1
    git config core.autocrlf false
    git branch -M main >nul 2>&1
    echo Repositorio local criado.
)
git config core.autocrlf false

REM --- token pessoal opcional (arquivo local, nunca versionado) ---
set "TOKEN="
if exist token_github.txt (
    for /f "usebackq delims=" %%T in ("token_github.txt") do set "TOKEN=%%T"
)
set "REMOTE_URL=https://github.com/junior700/Desktop_Agent_BASE44.git"
if defined TOKEN (
    set "REMOTE_URL=https://x-access-token:!TOKEN!@github.com/junior700/Desktop_Agent_BASE44.git"
    echo Token pessoal detectado - token_github.txt
) else (
    echo Sem token_github.txt - usara a credencial do Windows.
)

git remote get-url origin >nul 2>&1
if errorlevel 1 (
    git remote add origin "!REMOTE_URL!"
) else (
    git remote set-url origin "!REMOTE_URL!"
)

echo.
echo Arquivos modificados/novos:
echo ----------------------------------------
git status --short
echo ----------------------------------------
echo.

set "CONFIRMA="
set /p CONFIRMA="Continuar com add/commit/push? (S/n): "
if /i "!CONFIRMA!"=="n" (
    echo Cancelado.
    pause
    exit /b 0
)

echo.
echo Executando git add...
git add -A

echo.
set "MSG="
set /p MSG="Mensagem de commit (ENTER = 'Atualizar repositorio'): "
if not defined MSG set "MSG=Atualizar repositorio"

echo.
echo Criando commit...
git commit -m "!MSG!" >nul 2>&1
if errorlevel 1 (
    echo Nada novo para commitar - apenas sincronizando.
) else (
    echo Commit criado: !MSG!
)

REM --- baixa novidades ANTES do push (evita rejeicao) ---
git fetch origin >nul 2>&1
git rev-parse -q --verify origin/main >nul 2>&1
if not errorlevel 1 (
    git rev-parse -q --verify main >nul 2>&1
    if not errorlevel 1 (
        echo Baixando novidades do GitHub antes de enviar...
        git merge-base main origin/main >nul 2>&1
        if not errorlevel 1 (
            git pull --rebase origin main >nul 2>&1
        ) else (
            git pull --rebase -X theirs origin main >nul 2>&1
        )
        if errorlevel 1 (
            echo.
            echo CONFLITO ao baixar. Rebase cancelado - nada foi perdido.
            git rebase --abort >nul 2>&1
            echo Resolva com sincronizar_github.ps1 opcao 2 ou manualmente.
            pause
            exit /b 1
        )
    )
)

echo.
echo Fazendo push...
set "SAIDA=%TEMP%\git_push_saida.txt"
git push -u origin main > "%SAIDA%" 2>&1
if errorlevel 1 (
    echo.
    echo ========================================
    echo   ERRO no push
    echo ========================================
    type "%SAIDA%"
    findstr /C:"403" "%SAIDA%" >nul 2>&1
    if not errorlevel 1 (
        echo.
        echo PERMISSAO NEGADA 403: a conta usada nao tem escrita no repo.
        echo Crie token_github.txt nesta pasta com o token da conta
        echo junior700 - gerado em github.com/settings/tokens, escopo repo.
    )
    findstr /C:"rejected" "%SAIDA%" >nul 2>&1
    if not errorlevel 1 (
        echo.
        echo O GitHub tem mudancas novas. Rode este script de novo.
    )
    del "%SAIDA%" >nul 2>&1
    pause
    exit /b 1
)
del "%SAIDA%" >nul 2>&1

echo.
echo ========================================
echo   SUCESSO!
echo ========================================
pause
