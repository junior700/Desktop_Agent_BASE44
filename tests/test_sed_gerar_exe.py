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

    # --- FileLaunched/FILE0 batem com o nome do pacote ---
    check("Strings/AppLaunched aponta o .bat",
          cp.get("Strings", "AppLaunched") == "exemplo.bat")
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
