"""
test_menu_agente.py - Verificacao INTEGRAL do menu (agente.ps1).

REGRA DE OURO do usuario (26/09/2026): "TESTAR TODAS AS OPCOES DO
MENU A CADA PATCH (garante que nao gere bug cruzado ou
colateral)". Este modulo automatiza a parte estatica dessa regra:
cada opcao listada no menu tem caso correspondente no switch, os
guards de ambiente existem em TODA opcao que executa o $Venv, os
arquivos chamados existem no projeto, e nenhuma regressao conhecida
voltou (break dentro de switch, saida sem pausa, nao-ASCII).

Limitacao documentada (sandbox sem PowerShell): as checagens sao
ESTATICAS sobre o texto de agente.ps1; a execucao real das
opcoes e feita pelo usuario no Windows. Sandbox 3.11/sem libtk.

Origem (bug real do usuario, 26/09/2026): opcao [1] reportava
"Python 3.12 nao encontrado" quando o venv falhava com
"Errno 13 Permission denied: .venv\\Scripts\\python.exe" (venv em
uso) - o py -3.12 RODOU; o diagnostico era mentiroso. Fix: [a]
checar py --version primeiro, [b] .venv saudavel NAO e recriado
(recriar com ambiente em uso e a causa do Errno 13), [c] .venv
quebrado e apagado com orientacao de desbloqueio, e a saida REAL
do venv e exibida em caso de falha.
"""

import os
import re

BASE = os.path.join(os.path.dirname(__file__), "..")
AGENTE = os.path.join(BASE, "agente.ps1")


def _texto():
    with open(AGENTE, encoding="ascii") as f:
        return f.read()


def _opcoes_do_menu(t):
    """Extrai os numeros [n] listados SOMENTE na funcao Menu (linhas
    'Write-Host "  [n] ...' - 2 espacos apos a aspas; o aviso da
    propria Menu 'opcao [1] primeiro' nao e item de menu)."""
    return sorted(re.findall(r'Write-Host "(?:`n)?  \[(\d+)\] ', t), key=int)


def _casos_do_switch(t):
    """Extrai os numeros dos casos do switch."""
    return sorted(re.findall(r'^\s+"(\d+)" \{', t, re.M), key=int)


def _blocos_opcao(t):
    """Divide o switch em blocos {numero: texto-do-caso}."""
    # casos vao de "1" a "0", nesta ordem, no switch do menu
    partes = re.split(r'^\s+"(\d+)" \{', t, flags=re.M)
    blocos = {}
    for i in range(1, len(partes) - 1, 2):
        blocos[partes[i]] = partes[i + 1]
    return blocos


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731
    t = _texto()

    # === REGRA DE OURO: TODA opcao do menu tem caso no switch ===
    ops_menu = _opcoes_do_menu(t)
    ops_switch = _casos_do_switch(t)
    check("menu lista 11 opcoes (0 a 10)", ops_menu == [str(i) for i in range(11)])
    check("switch tem caso para cada opcao listada (menu == switch)",
          ops_menu == ops_switch and len(ops_switch) == 11)
    blocos = _blocos_opcao(t)
    check("parser de blocos enxergou os 11 casos",
          sorted(blocos.keys(), key=int) == [str(i) for i in range(11)])

    # === REGRA DE OURO: regressoes conhecidas NAO voltaram ===
    check("sem 'break' dentro do switch (gotcha PowerShell: '0 Sair' travava)",
          not re.search(r"^\s*break\s*$", t, re.M))
    check("saida controlada por flag $sair (nao por break)",
          '$sair = $false' in t and '$sair = $true' in t)
    check("opcao invalida tem feedback + Pause (default do switch)",
          "Opcao invalida" in t)
    check("agente.ps1: 100% ASCII (regra dos scripts de console)",
          all(b < 128 for b in open(AGENTE, "rb").read()))

    # === REGRA DE OURO: TUDO que executa $Venv tem guard de existencia ===
    for num, nome in [("2", "testes"), ("3", "dry-run"), ("4", "real"),
                      ("5", "recorder"), ("6", "dashboard")]:
        b = blocos.get(num, "")
        usa = ("$Venv" in b)
        guarda = ("Test-Path $Venv" in b)
        msg = ("opcao [1] primeiro" in b)
        check(f"opcao [{num}] ({nome}): executa venv SO com guard (Test-Path ou aviso)",
              (usa and guarda and msg) or (not usa))

    # === bug real do Errno 13: opcao 1 diagnostico verdadeiro ===
    b1 = blocos.get("1", "")
    check("opcao [1]: checa py -3.12 --version ANTES de culpar o Python",
          "py -3.12 --version" in b1)
    check("opcao [1]: .venv SAUDAVEL nao e recriado (causa do Errno 13)",
          ".venv ja existe - reconfirmando dependencias" in b1)
    check("opcao [1]: .venv QUEBRADO (pasta sem python.exe) e apagado e recriado",
          "Remove-Item -Recurse -Force" in b1 and "sem python.exe" in b1)
    check("opcao [1]: falha de apagar .venv travado orienta desbloqueio",
          "travado" in b1 and "Feche o" in b1)
    check("opcao [1]: saida REAL do venv exibida na falha (2>&1 capturado)",
          "py -3.12 -m venv .venv 2>&1" in b1)
    check("opcao [1]: sucesso verificado por Test-Path $Venv (nao so exit code)",
          "if (Test-Path $Venv)" in b1)
    check("opcao [1]: pip roda SO depois do venv confirmado",
          b1.index("if (Test-Path $Venv)") < b1.index("pip install -r requirements.txt"))
    check("opcao [1]: Tesseract OCR ainda e citado (regressao)",
          "UB-Mannheim/tesseract" in t)
    # === verificacao REAL de dependencias (pedido 26/09/2026: o [1]
    #     nunca CONFIRMOU que pytesseract & cia instalaram de verdade) ===
    check("opcao [1]: funcao Verificar-Deps existe",
          "function Verificar-Deps" in t)
    check("opcao [1]: Verificar-Deps checa as 7 libs (inclui pytesseract)",
          "pytesseract" in t and "pyautogui','pywinauto','pynput','PIL','pytesseract','cv2','jsonschema'" in t)
    check("opcao [1]: verificacao por IMPORT REAL (find_spec, nao so pip exit code)",
          "importlib.util" in t and "find_spec" in t)
    check("opcao [1]: distingue WRAPPER python da ENGINE tesseract.exe (where.exe)",
          "where.exe tesseract" in t and "tesseract.exe e separado" in t)
    check("opcao [1]: Verificar-Deps chamada nos 2 caminhos (venv novo + saudavel)",
          t.count("Verificar-Deps") >= 3)  # 1 def + 2 chamadas

    # === REGRA DE OURO: arquivos chamados por cada opcao EXISTEM ===
    for num, arq in [("2", "tests/run_all.py"), ("3", "main.py"),
                     ("5", "main.py"), ("6", "main.py"),
                     ("7", "sincronizar_github.ps1"),
                     ("8", "restrict/gerar_exe.ps1"),
                     ("10", "instalar_pytesseract.ps1")]:
        existe = os.path.exists(os.path.join(BASE, arq.replace("\\", "/")))
        chamado = arq.split("/")[-1] in blocos.get(num, "")
        check(f"opcao [{num}]: chama '{arq.split('/')[-1]}' e o arquivo existe no projeto",
              existe and chamado)

    check("opcao [9]: so roda patch.ps1 se existir (ovo-e-galinha documentado)",
          'if (Test-Path $p)' in blocos.get("9", ""))
    check("opcao [9]: injeta -ExecutionPolicy Bypass (trava avaliada antes do script)",
          "-NoProfile -ExecutionPolicy Bypass" in blocos.get("9", ""))
    check("opcao [8]: exe e gerado via IExpress com powershell -ExecutionPolicy Bypass",
          "-ExecutionPolicy Bypass" in blocos.get("8", ""))
    check("opcao [4]: modo REAL avisa ESC 3x antes de rodar",
          "ESC 3x" in blocos.get("4", ""))
    check("opcao [4]: SEM confirmacao duplicada no PS (a unica e no main.py)",
          "Continuar?" not in blocos.get("4", "") and
          "O main.py pedira confirmacao" in blocos.get("4", ""))

    # === PAUSA: toda saida visivel termina em pausa (regra anti-flash) ===
    sem_pausa = [n for n, b in blocos.items()
                 if n != "0" and "Pause" not in b and "$Venv" in b]
    check("toda opcao de acao termina com Pause (regra anti-flash)",
          len(sem_pausa) == 0)

    # === opcao [10]: instalar pytesseract SE AUSENTE (pedido do
    #     usuario 26/09/2026) - script separado que volta ao menu ===
    s10 = open(os.path.join(BASE, "instalar_pytesseract.ps1"),
               encoding="ascii").read()
    b10 = blocos.get("10", "")
    check("opcao [10]: chama instalar_pytesseract.ps1 via powershell -File",
          "instalar_pytesseract.ps1" in b10 and "-ExecutionPolicy Bypass" in b10)
    check("opcao [10]: script existe e chama powershell com -NoProfile",
          os.path.exists(os.path.join(BASE, "instalar_pytesseract.ps1")) and
          "-NoProfile -ExecutionPolicy Bypass" in b10)
    check("script [10]: guard de venv (opcao [1] primeiro se faltar)",
          "Test-Path $Venv" in s10 and "opcao [1]" in s10)
    check("script [10]: checa AUSENCIA por import REAL antes de instalar (find_spec)",
          "find_spec('pytesseract')" in s10 and
          s10.index("find_spec('pytesseract')") < s10.index("pip install"))
    check("script [10]: NAO reinstala se ja presente (SE AUSENTE)",
          "JA INSTALADO (import real OK). Nada a fazer." in s10)
    check("script [10]: verifica de NOVO apos instalar (pip exit 0 nao basta)",
          s10.count("find_spec('pytesseract')") >= 2)
    check("script [10]: checa ENGINE tesseract.exe (wrapper != engine)",
          "where.exe tesseract" in s10 and "UB-Mannheim/tesseract" in s10)
    check("script [10]: termina com pausa e avisa que volta ao menu (regra anti-flash)",
          s10.rstrip().endswith("Read-Host \"Pressione ENTER para voltar ao menu\""))
    check("script [10]: saida de erro do guard tambem tem pausa (regra)",
          s10.count("Read-Host") >= 2)
    check("script [10]: 100% ASCII",
          all(b < 128 for b in open(os.path.join(BASE, "instalar_pytesseract.ps1"), "rb").read()))

    # === dashboard: integracao com o minimize do console (v012) ===
    check("opcao [6]: abre dashboard via Start-Process (console minimizado pelo app)",
          "Start-Process $Venv" in blocos.get("6", ""))

    return results


if __name__ == "__main__":
    import sys
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)
