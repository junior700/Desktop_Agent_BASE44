"""
test_dashboard_ui.py - Testes estaticos do dashboard/app.py (Tkinter).

O sandbox de testes NAO tem libtk instalada (tkinter falha ao
importar: "libtk8.6.so: cannot open shared object file"), e o
projeto e Windows-only - mesma limitacao ja documentada para
sincronizar_github.ps1/gerar_exe.ps1. Estrategia: checagens
estaticas sobre o CODIGO-FONTE (AST + texto), a mesma usada em
test_sed_gerar_exe.py e test_sincronizar_token.py.

Motivacao (bug real 26/09/2026, screenshot do usuario): o botao
"Capturar tela agora" e o rotulo lbl_capdir ocupavam a MESMA
celula do grid (row=0, column=2) - colisao real do Tkinter que
desenhava os dois textos um sobre o outro ("Cap. capturas.jpg"
embaralhado na tela). Corrigido com reagrupamento em LabelFrame
e colunas distintas. Tambem adicionado: minimizar a janela do
console (CMD que o Start-Process abre) enquanto o dashboard esta
ativo, restaurando ao fechar - reuso do mecanismo do HumanRecorder.
"""

import ast
import os
import re

APP_PY = os.path.join(os.path.dirname(__file__), "..",
                      "dashboard", "app.py")


def _texto():
    with open(APP_PY, encoding="ascii") as f:
        return f.read()


def _grid_cells_por_frame(arvore, texto):
    """Mapeia, por GRUPO (frame/labelframe atual), o conjunto de
    (row, column) usados em .grid(...) - deteccao de colisao
    estatica (mesma logica do bug real: 2 widgets, mesma celula).

    O codigo widget->.grid() se estende por varias linhas (o
    construtor e o .grid() ficam em linhas diferentes), entao a
    varredura acompanha sequencialmente qual e o "grupo atual"
    (a ultima variavel de frame criada com ttk.Frame/ttk.LabelFrame)
    e atribui a ela toda .grid(row=N, column=M) encontrada depois,
    ate o proximo frame ser criado - reflete exatamente como o
    arquivo esta estruturado (bloco por bloco).
    """
    celulas = {}
    grupo_atual = None
    for linha in texto.splitlines():
        m_frame = re.search(
            r"^\s*(\w+)\s*=\s*ttk\.(?:Label)?Frame\(", linha)
        if m_frame:
            grupo_atual = m_frame.group(1)
            continue
        m = re.search(r"\.grid\(row=(\d+),\s*column=(\d+)", linha)
        if not m:
            continue
        chave = (grupo_atual, int(m.group(1)), int(m.group(2)))
        celulas.setdefault(chave, 0)
        celulas[chave] += 1
    return celulas


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731
    t = _texto()

    # --- AST valido (arquivo Windows-only, mas a SINTAXE e Python puro) ---
    arvore = ast.parse(t)
    check("dashboard/app.py: AST valido (sintaxe Python correta)",
          arvore is not None)

    # --- bug real: nenhuma celula de grid duplicada (colisao) ---
    celulas = _grid_cells_por_frame(arvore, t)
    duplicadas = {k: v for k, v in celulas.items() if v > 1}
    check("grid: nenhuma celula (frame, row, col) usada 2x (colisao real corrigida)",
          len(duplicadas) == 0)
    check("grid: pelo menos 8 widgets posicionados (grupos nao vazios)",
          sum(celulas.values()) >= 8)

    # --- reagrupamento em LabelFrame (pedido do usuario) ---
    check("layout: 3 grupos LabelFrame (Roteiro/Emergencia/Capturas)",
          t.count("ttk.LabelFrame(") == 3)
    check("layout: grupo Roteiro existe",
          'text="Roteiro"' in t)
    check("layout: grupo Emergencia existe e cita ESC 3x",
          'text="Emergencia (ou ESC 3x)"' in t)
    check("layout: grupo Capturas existe",
          'text="Capturas e gravacao"' in t)

    # --- textos de botao mais curtos (sem duplicar contexto do grupo) ---
    check("botao emergencia: 'PARAR TUDO' sem repetir '(emergencia)' 2x",
          'text="PARAR TUDO"' in t and
          t.count("(emergencia)") <= 1)  # so no titulo do grupo
    check("botao reset: texto curto 'Resetar'",
          'text="Resetar"' in t)
    check("botao captura: 'Capturar tela' (sem 'agora' redundante)",
          'text="Capturar tela"' in t)
    check("checkbox dry-run: texto encurtado",
          'text="Dry-run (simular)"' in t)

    # --- minimizar/restaurar console (novo pedido do usuario) ---
    check("console: importa minimize_console/restore_console do recorder (DRY)",
          "from agent.recorder.recorder import minimize_console, restore_console" in t)
    check("console: window_ctl injetavel no construtor (testavel, como o Recorder)",
          "def __init__(self, root: tk.Tk, window_ctl=None):" in t)
    check("console: minimiza ao abrir o dashboard",
          "self.window_ctl.minimize()" in t)
    check("console: restaura ao fechar (WM_DELETE_WINDOW -> _ao_fechar)",
          'root.protocol("WM_DELETE_WINDOW", self._ao_fechar)' in t and
          "self.window_ctl.restore()" in t)
    check("console: fechar realmente destroi a janela (nao so restaura)",
          "self.root.destroy()" in t)

    # --- regressoes das regras do projeto ---
    check("dashboard/app.py: 100% ASCII", all(b < 128 for b in
          open(APP_PY, "rb").read()))
    check("dashboard: montar_stack ainda chamado com keywords (bug da v007)",
          "confirmation_fn=self._confirmar_sensivel" in t and
          "on_event=" in t)

    return results


if __name__ == "__main__":
    import sys
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)
