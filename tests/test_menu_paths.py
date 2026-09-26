"""
test_menu_paths.py - Exercita os CAMINHOS REAIS das opcoes do menu.

Licao de um bug real (26/09/2026, opcao [5] do usuario): o loop do
recorder usava 'emergencia.triggered' - atributo QUE NAO EXISTE em
EmergencyStop (o metodo publico e is_triggered()) - AttributeError
na cara do usuario. A REGRA DE OURO de testar todas as opcoes do
menu existia (test_menu_agente.py) mas era estatica sobre o .ps1;
o bug estava no PYTHON chamado pelo menu.

Este modulo fecha a lacuna: varre o main.py (entrypoint de TODAS
as opcoes Python do menu: [3], [4], [5], [6]) via AST e confere
que CADA atributo acessado numa variavel construida por uma classe
do projeto existe de verdade na API dessa classe (metodos,
properties e self.<attr> publicos). E um mini-linter semantico - a
mesma classe de ver que um IDE faz, mas automatizada no run_all.

O sandbox nao importa main.py (imports de pyautogui/pywinauto),
por isso a analise e por AST: cobre todos os caminhos de codigo
sem rodar o Windows.
"""

import ast
import os
import re

BASE = os.path.join(os.path.dirname(__file__), "..")
MAIN_PY = os.path.join(BASE, "main.py")


def _mapa_imports(arvore):
    """ClassName -> arquivo do modulo (so imports 'from agent...')."""
    mapa = {}
    for no in ast.walk(arvore):
        if isinstance(no, ast.ImportFrom) and no.module and \
                no.module.startswith("agent."):
            caminho = no.module.replace(".", "/") + ".py"
            for alias in no.names:
                mapa[alias.asname or alias.name] = caminho
    return mapa


def _api_da_classe(arquivo, classe):
    """API publica da classe: metodos, @property e self.<attr>."""
    # arquivos do projeto podem ter acentos em docstrings (Python le
    # UTF-8 nativamente - a regra de ASCII puro e para .ps1/.bat)
    try:
        texto = open(arquivo, encoding="ascii").read()
    except UnicodeDecodeError:
        texto = open(arquivo, encoding="utf-8").read()
    arvore = ast.parse(texto)
    for no in arvore.body:
        if isinstance(no, ast.ClassDef) and no.name == classe:
            api = set()
            # @dataclass: campos declarados como 'nome: tipo = valor'
            # (AnnAssign com alvo Name no corpo da classe)
            for item in no.body:
                if isinstance(item, ast.AnnAssign) and \
                        isinstance(item.target, ast.Name) and \
                        not item.target.id.startswith("_"):
                    api.add(item.target.id)
            for item in no.body:
                if isinstance(item, ast.FunctionDef):
                    api.add(item.name)
                    if any(isinstance(d, ast.Name) and d.id == "property"
                           for d in item.decorator_list):
                        pass  # property e acessada como attr: ja esta no set
                for sub in ast.walk(item):
                    if isinstance(sub, ast.Assign):
                        for alvo in sub.targets:
                            if isinstance(alvo, ast.Attribute) and \
                                    isinstance(alvo.value, ast.Name) and \
                                    alvo.value.id == "self" and \
                                    not alvo.attr.startswith("_"):
                                api.add(alvo.attr)
            return api
    return set()


def _vars_por_classe(arvore, mapa_imports):
    """var -> classe, para 'var = Classe(...)' em QUALQUER escopo."""
    vars_ = {}
    for no in ast.walk(arvore):
        if isinstance(no, ast.Assign) and len(no.targets) == 1 and \
                isinstance(no.targets[0], ast.Name) and \
                isinstance(no.value, ast.Call) and \
                isinstance(no.value.func, ast.Name) and \
                no.value.func.id in mapa_imports:
            vars_[no.targets[0].id] = no.value.func.id
    return vars_


def _titulo_janela_ativa_rapido():
    """Chama a funcao real: no sandbox (Linux) deve voltar '' na hora."""
    import sys
    sys.path.insert(0, os.path.join(BASE))
    import time as _t
    from agent.runtime import titulo_janela_ativa
    ini = _t.monotonic()
    titulo = titulo_janela_ativa()
    return (_t.monotonic() - ini) < 1.0 and titulo == ""


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    fonte = open(MAIN_PY, encoding="ascii").read()
    arvore = ast.parse(fonte)
    mapa_imports = _mapa_imports(arvore)
    vars_ = _vars_por_classe(arvore, mapa_imports)

    check("main.py: AST valido", True)
    check("main.py: importa EmergencyStop (opcoes [3]/[4]/[5] usam)",
          "EmergencyStop" in mapa_imports)
    check("main.py: importa HumanRecorder (opcao [5])",
          "HumanRecorder" in mapa_imports)
    check("main.py: variaveis construidas por classes do projeto detectadas",
          len(vars_) >= 2 and "emergencia" in vars_ and "rec" in vars_)

    # === CRUZAMENTO: cada <var>.<attr> acessado existe na API real ===
    acessos = set()
    for no in ast.walk(arvore):
        if isinstance(no, ast.Attribute) and \
                isinstance(no.value, ast.Name) and \
                no.value.id in vars_:
            acessos.add((no.value.id, no.attr))

    check("main.py: ha acessos a checar (linter nao esta cego)",
          len(acessos) >= 5)

    erros = []
    cobertos = 0
    for var, attr in sorted(acessos):
        classe = vars_[var]
        arquivo = os.path.join(BASE, mapa_imports[classe])
        if not os.path.exists(arquivo):
            erros.append(f"{var}.{attr}: arquivo {arquivo} nao existe")
            continue
        api = _api_da_classe(arquivo, classe)
        if attr not in api:
            erros.append(f"{var}.{attr}: NAO existe na API de {classe} "
                         f"(opcoes: {sorted(api)[:8]}...)")
        else:
            cobertos += 1

    check(f"CRUZAMENTO: TODOS os {len(acessos)} acessos existem nas APIs "
          f"reais ({cobertos} confirmados)", len(erros) == 0)
    for e in erros:
        check("  erro: " + e, False)

    # === QuickEdit (bug real 26/09/2026: clique do usuario no console
    #     congela o processo - 'deu uma bloqueada', ESC 3x pareceu morto) ===
    rec_mod = open(os.path.join(BASE, "agent", "recorder", "recorder.py"),
                   encoding="ascii").read()
    check("console: disable_quickedit existe no recorder",
          "def disable_quickedit" in rec_mod and
          "ENABLE_QUICK_EDIT" in rec_mod and
          "ENABLE_EXTENDED_FLAGS" in rec_mod)
    check("console: main.py DESATIVA QuickEdit antes de tudo",
          "disable_quickedit()" in fonte and
          fonte.index("disable_quickedit()") <
          fonte.index('ap = argparse.ArgumentParser'))
    check("console: dashboard tambem desativa QuickEdit",
          "quickedit_off()" in open(os.path.join(BASE, "dashboard", "app.py"),
                                    encoding="ascii").read())
    check("[4]: retorno do emergencia.start() VERIFICADO (listener)",
          "if not emergencia.start():" in fonte)
    check("[4]: banner avisa kill switch do canto (independe de foco)",
          "canto sup. esquerdo" in fonte)

    # === modo REAL (opcao [4]): congelamento + UX (bug real 26/09/2026,
    #     o agente travou ANTES do primeiro clique, console parado) ===
    rt = open(os.path.join(BASE, "agent", "runtime.py"),
              encoding="ascii").read()
    check("[3]/[4]: titulo_janela_ativa usa Win32 nativo (GetForegroundWindow)",
          "GetForegroundWindow" in rt and "GetWindowTextW" in rt)
    check("[3]/[4]: REGRESSAO congelamento: SEM pywinauto UIA no titulo",
          "backend=\"uia\"" not in rt and "get_active()" not in rt)
    check("[3]/[4]: titulo_janela_ativa responde rapido no sandbox",
          _titulo_janela_ativa_rapido())
    check("[4]: EXATAMENTE UMA confirmacao Continuar no main.py (sem dupla)",
          fonte.count('input("Continuar? [s/N] ")') == 1)
    check("[4]: minimiza console ANTES de executar no modo REAL",
          fonte.index("minimize_console()") <
          fonte.index("interpreter.run_file(args.roteiro)"))
    check("[4]: restaura console no fim E no finally (ESC/erro tambem)",
          fonte.count("restore_console()") >= 2 and
          "restore_console()" in fonte.split("finally:")[1])
    check("[4]: minimizar vem do recorder (mesmo codigo do F12/F10)",
          "from agent.recorder.recorder import minimize_console, restore_console"
          in fonte)

    # === regressao do bug real: o typo NAO pode voltar ===
    check("BUG REAL [5]: 'emergencia.triggered' (attr inexistente) ausente",
          "emergencia.triggered" not in re.sub(r"is_triggered", "", fonte))
    check("[5]: loop usa o metodo publico is_triggered()",
          "emergencia.is_triggered()" in fonte)
    check("[5]: rec.is_stopped e property real do HumanRecorder",
          "rec.is_stopped" in fonte and "is_stopped" in
          _api_da_classe(os.path.join(BASE, mapa_imports["HumanRecorder"]),
                         "HumanRecorder"))

    return results


if __name__ == "__main__":
    import sys
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)
