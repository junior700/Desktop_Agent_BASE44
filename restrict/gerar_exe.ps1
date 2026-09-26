# ============================================================
# gerar_exe.ps1 - Transforma os fontes .bin de restrict\ em .exe
#
# COMO FUNCIONA:
#   - Ferramenta: IExpress, NATIVO do Windows (nada a instalar).
#   - Para cada *.bin em restrict\: copia para uma pasta TEMPORARIA
#     com a extensao .bat restaurada, gera o .SED e roda:
#         iexpress.exe /N /Q /M <arquivo>.SED
#   - O .bat real so existe no %TEMP% durante o build; ao final a
#     pasta temporaria e apagada (mantida em caso de erro, para
#     inspecao do SED). Fonte e zip ficam limpos.
#   - O .exe gerado sai na RAIZ do projeto (um nivel acima de
#     restrict\): ex. publicar_github.exe.
#
# CORRECAO v4 (falha real ao EXECUTAR o .exe gerado, apos v3 corrigir
# o BUILD): "Erro ao criar o processo com Command.com /c ...bat" +
# "sistema nao pode encontrar o arquivo especificado". Causa: quando
# AppLaunched e so o nome do .bat (sem "cmd /c"), o IExpress tenta
# lancar via COMMAND.COM (interprete DOS de 16 bits) em vez de
# cmd.exe - COMMAND.COM nao funciona no Windows 64 bits. Confirmado
# contra DUAS referencias independentes que usam "cmd /c" explicito:
# guia de empacotamento IExpress (gist h3r/Cool-Retro-Term-Windows10)
# e o SED do ps2exe-iexpress (github.com/Ramikan/Shelling), que fazem
# AppLaunched=cmd /c "arquivo" - nunca o nome nu.
#
# CORRECOES v3 (falha na CRIACAO do .exe, codigo 1 do IExpress):
#   1) SED [Options] usa o LITERAL "SourceFiles=SourceFiles" -
#      antes era "SourceFiles=%SourceFiles%" com a variavel
#      %SourceFiles% NUNCA definida em [Strings]; o IExpress
#      abortava na substituicao (exit 1). Confirmado contra o
#      SED funcional do ps2exe-iexpress (github.com/Ramikan/Shelling)
#      e o formato do assistente (wizard) do Windows.
#   2) UseLongFileName=1 (antes 0; caminhos longos do %TEMP%).
#   3) Fallback de arquitetura: se o iexpress de System32 falhar,
#      tenta o de SysWOW64 (32 bits, usado de proposito pela
#      referencia "para maior compatibilidade").
#   4) Exe antigo removido antes do build (IExpress nao gosta de
#      sobrescrever destino existente).
#
# USO (na raiz do projeto, ou pela opcao [8] do agente.ps1):
#   powershell -ExecutionPolicy Bypass -File .\restrict\gerar_exe.ps1
#
# NOTA HONESTA (antivirus): o .exe gerado NAO e assinado; o
# SmartScreen/antivirus pode mostrar "app nao reconhecido" na
# primeira vez ("Mais informacoes" -> "Executar assim mesmo").
# O que o .exe faz e exatamente o que o .bin diz.
# ============================================================

$ErrorActionPreference = "Stop"

$Restrict = $PSScriptRoot                      # ...projeto\restrict
$Raiz     = Split-Path $Restrict -Parent       # ...projeto

# --- iexpress: 64 bits (padrao) com fallback 32 bits (compat) ---
$IExpresses = @(
    (Join-Path $env:WINDIR "System32\iexpress.exe")
    (Join-Path $env:WINDIR "SysWOW64\iexpress.exe")
) | Where-Object { Test-Path $_ }

if ($IExpresses.Count -eq 0) {
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
    $nome     = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $destExe  = Join-Path $Raiz "$nome.exe"

    # exe antigo fora (IExpress nao sobrescreve bem destino existente)
    Remove-Item $destExe -Force -ErrorAction SilentlyContinue

    # pasta TEMPORARIA do build (o .bat so vive aqui, e morre aqui)
    $suf = [IO.Path]::GetRandomFileName() -replace "\.", ""
    $tmp = Join-Path $env:TEMP ("gerar_exe_{0}_{1}" -f $nome, $suf)
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $batTmp = Join-Path $tmp "$nome.bat"
    Copy-Item $f.FullName $batTmp

    # SED: diretiva do IExpress no formato do assistente (wizard),
    # conferido contra ps2exe-iexpress (github.com/Ramikan/Shelling)
    $sed = Join-Path $tmp "$nome.SED"
    $sedConteudo = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
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
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
FriendlyName=$nome
TargetName=$destExe
AppLaunched=cmd /c "$nome.bat"
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

    # build silencioso: /N sem assistente, /Q quiet, /M a partir do SED.
    # fallback: System32 (64b) falhou -> tenta SysWOW64 (32b)
    $erro = $true
    $codErro = 1
    foreach ($ie in $IExpresses) {
        & $ie "/N" "/Q" "/M" $sed | Out-Null
        $codErro = $LASTEXITCODE
        if ($codErro -eq 0 -and (Test-Path $destExe)) {
            $erro = $false
            break
        }
        Write-Host "       tentativa com $ie falhou (codigo $codErro); tentando proximo..." -ForegroundColor Yellow
    }

    if (-not $erro) {
        Write-Host "[OK] $($f.Name) -> $nome.exe" -ForegroundColor Green
        $gerados++
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "[ERRO] $($f.Name): iexpress falhou (codigo $codErro)." -ForegroundColor Red
        Write-Host "       SED preservado para inspecao: $sed" -ForegroundColor Yellow
        Write-Host "       Abra um relatorio: envie o conteudo do SED acima." -ForegroundColor Yellow
    }
}

Write-Host ""
if ($gerados -gt 0) {
    Write-Host ("{0} executavel(is) gerado(s) na raiz do projeto." -f $gerados) -ForegroundColor Green
    Write-Host "Primeira execucao pode mostrar o aviso do SmartScreen" -ForegroundColor Yellow
    Write-Host "(nao assinado): 'Mais informacoes' -> 'Executar assim mesmo'." -ForegroundColor Yellow
}
Read-Host "Pressione ENTER para fechar" | Out-Null
exit 0
