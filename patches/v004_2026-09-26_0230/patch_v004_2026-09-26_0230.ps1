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

    "restrict\gerar_exe.ps1" = @'
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

'@
    "tests\test_sed_gerar_exe.py" = @'
"""test_sed_gerar_exe.py - Testes do SED gerado por restrict/gerar_exe.ps1.

O bug real de 25/09/2026: [Options] referenciava %SourceFiles%, que
nunca era definido em [Strings] -> IExpress abortava com codigo 1
na primeira execucao da opcao [8] do menu. Este modulo extrai o
template SED do .ps1 e valida a construcao ANTES do build no
Windows (IExpress nao existe no sandbox, mas o SED e texto).
"""
import configparser
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

PS1 = os.path.join(os.path.dirname(__file__), "..", "restrict", "gerar_exe.ps1")


def _extrair_template_sed():
    """Extrai o here-string @\"...\"@ com o template SED do gerar_exe.ps1."""
    with open(PS1, encoding="ascii") as f:
        texto = f.read()
    m = re.search(r'\$sedConteudo = @"(?P<corpo>.*?)"@', texto, re.S)
    assert m, "template SED nao encontrado em gerar_exe.ps1"
    corpo = m.group("corpo").strip("\r\n")
    # substitui as variaveis PowerShell por valores de exemplo
    corpo = corpo.replace("$nome", "exemplo")
    corpo = corpo.replace("$destExe", r"C:\proj\exemplo.exe")
    corpo = corpo.replace("$tmp", r"C:\Users\u\AppData\Local\Temp\tmp1")
    return corpo


def _sed_parseado(sed):
    """Parseia o SED sem interpolacao (% e literal, nao diretorio)."""
    cp = configparser.RawConfigParser(strict=False)
    cp.optionxform = str  # preserva caixa alta/baixa das chaves
    cp.read_string(sed)
    return cp


def _vars_referenciadas(texto):
    """%VAR% presentes num trecho do SED."""
    return set(re.findall(r"%([A-Za-z0-9]+)%", texto))


def run_all():
    """Roda todas as validacoes; retorna [(nome, ok), ...]."""
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # --- pre-condicao: arquivo existe e e ASCII puro (regra) ---
    try:
        with open(PS1, encoding="ascii") as f:
            texto_ps1 = f.read()
        check("gerar_exe.ps1 e ASCII puro", True)
    except UnicodeDecodeError:
        check("gerar_exe.ps1 e ASCII puro", False)
        return results

    try:
        sed = _extrair_template_sed()
        check("template SED extraido", True)
    except AssertionError as e:
        check(f"template SED extraido ({e})", False)
        return results

    cp = _sed_parseado(sed)

    # --- o bug real: SourceFiles deve ser LITERAL, nunca %SourceFiles% ---
    valor = cp.get("Options", "SourceFiles")
    check("SourceFiles=SourceFiles (literal do wizard)",
          valor == "SourceFiles")

    # --- toda %VAR% de [Options] tem que existir em [Strings] ---
    faltando = []
    for chave, valor_opt in cp.items("Options"):
        for var in _vars_referenciadas(valor_opt):
            if not cp.has_option("Strings", var):
                faltando.append(f"%{var}% em {chave}")
    check("toda %VAR% de [Options] definida em [Strings]", not faltando)

    # --- campos obrigatorios do formato do assistente ---
    check("Version/Class=IEXPRESS", cp.get("Version", "Class") == "IEXPRESS")
    check("Version/SEDVersion=3", cp.get("Version", "SEDVersion") == "3")
    check("Options/PackagePurpose=InstallApp",
          cp.get("Options", "PackagePurpose") == "InstallApp")
    check("Options/RebootMode=N", cp.get("Options", "RebootMode") == "N")
    check("Options/UseLongFileName=1 (caminhos longos do TEMP)",
          cp.get("Options", "UseLongFileName") == "1")

    # --- AppLaunched: NUNCA nome nu do .bat (bug real 25/09/2026) ---
    # "AppLaunched=exemplo.bat" faz o IExpress cair no fallback
    # COMMAND.COM (16 bits), que nao existe no Windows 64 bits ->
    # "Erro ao criar o processo com Command.com /c ... nao pode
    # encontrar o arquivo especificado" ao RODAR o .exe (o build
    # ate funciona; so a execucao falha). Tem que ser "cmd /c" e
    # o .bat entre aspas.
    app = cp.get("Strings", "AppLaunched")
    check("AppLaunched usa cmd /c (nao dispara COMMAND.COM)",
          app.lower().startswith("cmd /c"))
    check("AppLaunched referencia o .bat entre aspas",
          '"exemplo.bat"' in app)
    check("AppLaunched NAO e o nome nu do .bat (regressao do bug real)",
          app != "exemplo.bat")
    file0 = cp.get("Strings", "FILE0")
    check('Strings/FILE0 com aspas canonicas', file0 == '"exemplo.bat"')

    check("secao [SourceFiles] existe", cp.has_section("SourceFiles"))
    check("secao [SourceFiles0] existe", cp.has_section("SourceFiles0"))
    if cp.has_section("SourceFiles0"):
        check("[SourceFiles0] espelha FILE0",
              cp.get("SourceFiles0", "%FILE0%") == '"exemplo.bat"')
    if cp.has_section("SourceFiles"):
        src0 = cp.get("SourceFiles", "SourceFiles0")
        check("SourceFiles0 com barra final", src0.endswith("\\"))

    # --- regra do projeto: nenhum exit sem pausa (Read-Host) antes ---
    linhas = [l.strip() for l in texto_ps1.splitlines()]
    sem_pausa = []
    for i, l in enumerate(linhas):
        if l.startswith("exit "):
            janela = "\n".join(linhas[max(0, i - 6):i])
            if "Read-Host" not in janela:
                sem_pausa.append(l)
    check("todo exit tem Read-Host antes", not sem_pausa)

    # --- fallback 32 bits presente (correcao v3) ---
    check("fallback SysWOW64 presente",
          "SysWOW64" in texto_ps1 and "foreach ($ie in $IExpresses)" in texto_ps1)

    return results


if __name__ == "__main__":
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)

'@

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "restrict\gerar_exe.ps1" = "9381895A05C9B683D6386AA45792D3389A027C8E5A9C0410744EC2642061DCC9"
    "tests\test_sed_gerar_exe.py" = "5A808E1D2844B2E20E73F3EDDD150C7E8AE8E6ACAB725900D80BF2DE931B2A4E"

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
