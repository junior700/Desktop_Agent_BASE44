# ============================================================
#  instalar_pytesseract.ps1
#  Instala o pytesseract (wrapper Python) SE AUSENTE, verifica
#  de verdade (import real) e checa a ENGINE Tesseract.
#  Ao terminar, a janela do menu original (agente.ps1) volta ao
#  controle - este script e chamado pela opcao [10] do menu.
#
#  Armadilha classica do OCR: pip instala so o WRAPPER Python
#  (pytesseract); o PROGRAMA tesseract.exe e separado (UB-
#  Mannheim). Wrapper sem engine quebra em runtime com
#  TesseractNotFoundError.
# ============================================================

$Proj = $PSScriptRoot
$Venv = Join-Path $Proj ".venv\Scripts\python.exe"

Write-Host "=== Instalar pytesseract (se ausente) ===" -ForegroundColor Cyan
Write-Host "Pasta do projeto: $Proj`n"

# [guard] o venv tem que existir (instalado pela opcao [1] do menu)
if (-not (Test-Path $Venv)) {
    Write-Host "ERRO: .venv nao encontrado. Rode a opcao [1] do menu" -ForegroundColor Red
    Write-Host "primeiro (instala o ambiente completo)." -ForegroundColor Red
    Read-Host "Pressione ENTER para voltar ao menu"
    exit 1
}

# [checagem real] wrapper ja instalado? IMPORT de verdade, nao so
# confiar no historico do pip (find_spec no python DO venv)
& $Venv -c "import importlib.util as iu; raise SystemExit(0 if iu.find_spec('pytesseract') else 1)"
if ($LASTEXITCODE -eq 0) {
    Write-Host "pytesseract: JA INSTALADO (import real OK). Nada a fazer."
}
else {
    Write-Host "pytesseract: AUSENTE. Instalando no venv..."
    & $Venv -m pip install "pytesseract>=0.3.10"
    # [verificacao REAL pos-instalacao] - pip pode terminar em exit 0
    # sem a lib utilizavel; o import e a prova final
    & $Venv -c "import importlib.util as iu; raise SystemExit(0 if iu.find_spec('pytesseract') else 1)"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "pytesseract: INSTALADO COM SUCESSO (import real OK)." -ForegroundColor Green
    }
    else {
        Write-Host "ERRO: a instalacao falhou (import continua ausente)." -ForegroundColor Red
        Write-Host "Rode a opcao [1] do menu para o diagnostico completo" -ForegroundColor Yellow
        Write-Host "das 7 dependencias." -ForegroundColor Yellow
    }
}

# [engine] wrapper sem engine quebra em tempo de execucao
$eng = where.exe tesseract 2>$null
if ($eng) {
    Write-Host "ENGINE Tesseract OCR: OK ($eng)"
}
else {
    Write-Host "ENGINE Tesseract OCR: NAO ENCONTRADA no PATH." -ForegroundColor Yellow
    Write-Host "O pytesseract e so o WRAPPER Python; o PROGRAMA"
    Write-Host "tesseract.exe e separado (instalador do Windows)."
    Write-Host "Sem ele, OCR falha em runtime. Instale em:"
    Write-Host "  https://github.com/UB-Mannheim/tesseract/wiki"
}

Write-Host "`nVoltando ao menu do agente..." -ForegroundColor Cyan
Read-Host "Pressione ENTER para voltar ao menu"
