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
    return sorted(re.findall(r'Write-Host "(?:`n)?  \[(\d)\] ', t))


def _casos_do_switch(t):
    """Extrai os numeros dos casos do switch."""
    return sorted(re.findall(r'^\s+"(\d)" \{', t, re.M))


def _blocos_opcao(t):
    """Divide o switch em blocos {numero: texto-do-caso}."""
    # casos vao de "1" a "0", nesta ordem, no switch do menu
    partes = re.split(r'^\s+"(\d)" \{', t, flags=re.M)
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
    check("menu lista 10 opcoes (0 a 9)", ops_menu == [str(i) for i in range(10)])
    check("switch tem caso para cada opcao listada (menu == switch)",
          ops_menu == ops_switch and len(ops_switch) == 10)
    blocos = _blocos_opcao(t)
    check("parser de blocos enxergou os 10 casos",
          sorted(blocos.keys()) == [str(i) for i in range(10)])

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
          "UB-Mannheim/tesseract" in b1)

    # === REGRA DE OURO: arquivos chamados por cada opcao EXISTEM ===
    for num, arq in [("2", "tests/run_all.py"), ("3", "main.py"),
                     ("5", "main.py"), ("6", "main.py"),
                     ("7", "sincronizar_github.ps1"),
                     ("8", "restrict/gerar_exe.ps1")]:
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
    check("opcao [4]: modo REAL exige confirmacao explicita [s/N]",
          "Continuar? [s/N]" in blocos.get("4", ""))
    check("opcao [4]: modo REAL avisa ESC 3x antes de rodar",
          "ESC 3x" in blocos.get("4", ""))

    # === PAUSA: toda saida visivel termina em pausa (regra anti-flash) ===
    sem_pausa = [n for n, b in blocos.items()
                 if n != "0" and "Pause" not in b and "$Venv" in b]
    check("toda opcao de acao termina com Pause (regra anti-flash)",
          len(sem_pausa) == 0)

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
