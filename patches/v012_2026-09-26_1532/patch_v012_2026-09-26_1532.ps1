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

    "dashboard\app.py" = @'
"""
app.py - Dashboard Tkinter do agente de desktop.

Funcionalidades:
- Carregar roteiro via seletor de arquivos (File Explorer)
- Executar roteiro com modo dry-run (default LIGADO) ou real
- Feed ao vivo das acoes (executada/bloqueada/dry_run)
- Estatisticas do audit log (total/permitidas/bloqueadas/executadas)
- Confirmacao de acoes sensiveis (janela modal)
- Botao de PARADA DE EMERGENCIA e reset (ESC 3x tambem funciona)

O roteiro roda numa THREAD separada; a UI nunca trava.
Eventos chegam a UI via fila (thread-safe).
"""

from __future__ import annotations

import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from agent.config import AgentConfig
from agent.safety.emergency_stop import EmergencyStop
from agent.safety.logger import AuditLogger
from agent.runtime import montar_stack
from agent.ui.native_dialogs import selecionar_arquivo, selecionar_pasta
# minimize/restore da janela do console - mesmo mecanismo do Human
# Recorder (ctypes GetConsoleWindow + ShowWindow), reaproveitado aqui
# para nao duplicar codigo Win32 (DRY).
from agent.recorder.recorder import minimize_console, restore_console


class Dashboard:
    def __init__(self, root: tk.Tk, window_ctl=None):
        self.root = root
        root.title("Desktop Agent - Painel de Controle")
        root.geometry("900x580")
        root.minsize(760, 480)

        # controlador da janela do console: minimiza agora que o
        # dashboard esta ativo, restaura quando o usuario fechar
        # (injetavel para testes - mesmo padrao do HumanRecorder)
        if window_ctl is None:
            window_ctl = type("ConsoleWindowCtl", (), {
                "minimize": staticmethod(minimize_console),
                "restore": staticmethod(restore_console),
            })()
        self.window_ctl = window_ctl
        self.window_ctl.minimize()
        root.protocol("WM_DELETE_WINDOW", self._ao_fechar)

        self.config = AgentConfig()
        self.config.validate()
        self.emergency = EmergencyStop(
            presses_required=self.config.emergency_esc_presses,
            window_s=self.config.emergency_window_s)
        self.emergency.start()
        self.logger = AuditLogger(self.config.audit_db_path)

        # Stack UNICA compartilhada com o CLI (agent/runtime.py)
        self.interpreter, self.refs = montar_stack(
            self.config, self.emergency, self.logger,
            confirmation_fn=self._confirmar_sensivel,
            on_event=lambda fase, ac, v: self.events.put((fase, ac, v.reason)))

        self.events: "queue.Queue[tuple]" = queue.Queue()
        self.script_path: str | None = None
        self.runner_thread: threading.Thread | None = None

        self._build_ui()
        self.root.after(200, self._drain_events)

    # ------------------------------------------------------------------
    def _ao_fechar(self):
        """Restaura a janela do console (minimizada ao abrir) e fecha."""
        self.window_ctl.restore()
        self.root.destroy()

    # ------------------------------------------------------------------
    def _build_ui(self):
        """Botoes agrupados por proposito (ttk.LabelFrame).

        Bug real corrigido (26/09/2026, screenshot do usuario): o
        botao 'Capturar tela agora' e o rotulo lbl_capdir ocupavam a
        MESMA celula do grid (row=0, column=2 em topo2) - colisao
        real do Tkinter, as duas legendas ficavam desenhadas uma
        sobre a outra (o texto 'embaralhado' na tela). Agrupar em
        LabelFrame tambem elimina o excesso de texto repetido em
        cada botao (ex.: '(emergencia)' 2x) - o titulo do grupo ja
        da o contexto.
        """
        pad = {"padx": 6, "pady": 4}

        grp_roteiro = ttk.LabelFrame(self.root, text="Roteiro")
        grp_roteiro.pack(fill="x", padx=10, pady=(8, 4))

        ttk.Button(grp_roteiro, text="Abrir roteiro...",
                   command=self.abrir_roteiro).grid(row=0, column=0, **pad)
        self.lbl_arquivo = ttk.Label(grp_roteiro,
                                     text="(nenhum roteiro carregado)")
        self.lbl_arquivo.grid(row=0, column=1, sticky="w", **pad)

        self.var_dry = tk.BooleanVar(value=True)
        ttk.Checkbutton(grp_roteiro, text="Dry-run (simular)",
                        variable=self.var_dry).grid(row=0, column=2, **pad)

        self.btn_run = ttk.Button(grp_roteiro, text="EXECUTAR",
                                  command=self.executar, style="Accent.TButton")
        self.btn_run.grid(row=0, column=3, **pad)
        grp_roteiro.columnconfigure(1, weight=1)

        grp_emerg = ttk.LabelFrame(self.root, text="Emergencia (ou ESC 3x)")
        grp_emerg.pack(fill="x", padx=10, pady=4)

        ttk.Button(grp_emerg, text="PARAR TUDO",
                   command=self._parar_tudo).grid(row=0, column=0, **pad)
        ttk.Button(grp_emerg, text="Resetar",
                   command=self._reset_emergencia).grid(row=0, column=1, **pad)

        grp_cap = ttk.LabelFrame(self.root, text="Capturas e gravacao")
        grp_cap.pack(fill="x", padx=10, pady=4)

        ttk.Button(grp_cap, text="Gravar cliques...",
                   command=self.gravar_cliques).grid(row=0, column=0, **pad)
        ttk.Button(grp_cap, text="Capturar tela",
                   command=self.capturar_agora).grid(row=0, column=1, **pad)
        ttk.Button(grp_cap, text="Pasta de capturas...",
                   command=self.escolher_pasta_capturas).grid(row=0, column=2, **pad)
        self.lbl_capdir = ttk.Label(grp_cap, text=self._nome_capdir())
        self.lbl_capdir.grid(row=0, column=3, sticky="w", **pad)
        grp_cap.columnconfigure(3, weight=1)

        meio = ttk.Frame(self.root)
        meio.pack(fill="both", expand=True, padx=10, pady=(4, 0))

        ttk.Label(meio, text="Feed de execucao:").pack(anchor="w")
        self.txt_feed = tk.Text(meio, height=16, state="disabled",
                                font=("Consolas", 10))
        self.txt_feed.pack(fill="both", expand=True)

        baixo = ttk.Frame(self.root)
        baixo.pack(fill="x", padx=10, pady=8)
        self.lbl_stats = ttk.Label(baixo, text="-")
        self.lbl_stats.pack(anchor="w")
        self.lbl_status = ttk.Label(baixo, text="Status: idle")
        self.lbl_status.pack(anchor="e")
        self._atualiza_stats()

    # ------------------------------------------------------------------
    def abrir_roteiro(self):
        # Janela nativa do Windows, ja aberta em scripts\
        path = selecionar_arquivo(pasta="scripts")
        if path:
            self.script_path = path
            self.lbl_arquivo.config(text=os.path.basename(path))

    # ------------------------------------------------------------------
    def executar(self):
        if not self.script_path:
            messagebox.showwarning("Sem roteiro", "Carregue um roteiro JSON antes.")
            return
        if self.runner_thread and self.runner_thread.is_alive():
            messagebox.showwarning("Ocupado", "Um roteiro ja esta em execucao.")
            return
        if self.emergency.is_triggered():
            messagebox.showerror("Emergencia ativa",
                                "Reset a emergencia antes de executar.")
            return

        modo_real = not self.var_dry.get()
        if modo_real and not messagebox.askyesno(
                "CONFIRMACAO",
                "Executar em modo REAL (mouse/teclado serao controlados)?\n\n"
                "ESC 3x interrompe tudo."):
            return

        self.config.dry_run = self.var_dry.get()
        self._feed(f"=== executando {os.path.basename(self.script_path)} "
                   f"({'dry-run' if self.config.dry_run else 'REAL'}) ===")

        def roda():
            try:
                res = self.interpreter.run_file(self.script_path)
                msg = (f"CONCLUIDO ok={res.ok} executadas={res.executadas} "
                       f"bloqueadas={res.bloqueadas} {res.abort_reason}")
            except Exception as e:  # noqa: BLE001 - erro vira feed, nao crash
                msg = f"FALHOU: {e}"
            self.events.put(("fim", None, msg))

        self.runner_thread = threading.Thread(target=roda, daemon=True)
        self.runner_thread.start()
        self.lbl_status.config(text="Status: executando...")

    def _confirmar_sensivel(self, ac) -> bool:
        """Janela modal p/ acao sensivel; timeout = negada (fail-safe)."""
        res = {"ok": False}
        ev = threading.Event()

        def pergunta():
            res["ok"] = messagebox.askyesno(
                "ACAO SENSIVEL",
                f"Acao: {ac.get('tipo')}\n{ac}\n\nAprovar execucao?")
            ev.set()
        self.root.after(0, pergunta)
        ev.wait(timeout=self.config.confirmation_timeout_s)
        return res["ok"]

    # ------------------------------------------------------------------
    # Recorder + pasta de capturas (janelas nativas do Windows)
    # ------------------------------------------------------------------
    def gravar_cliques(self):
        """Grava cliques humanos; saiida escolhida em janela nativa
        ja aberta em scripts\\. F12 encerra a gravacao."""
        if self.runner_thread and self.runner_thread.is_alive():
            messagebox.showwarning("Ocupado", "Aguarde a execucao atual terminar.")
            return
        path = selecionar_arquivo(pasta="scripts", salvar=True,
                                  nome_default="gravacao.json")
        if not path:
            return
        self._feed("=== recorder armado: F12 INICIA, F10 ENCERRA ===")

        from agent.recorder.recorder import HumanRecorder
        rec = HumanRecorder(self.config, emergency=self.emergency)
        estado = {}

        def roda():
            if not rec.arm():
                self.events.put(("fim", None, "recorder: pynput indisponivel"))
                return
            self.events.put(("aviso", None,
                             "recorder armado: aperte F12 p/ iniciar"))
            import time as _t
            while not rec.is_stopped and not self.emergency.is_triggered():
                _t.sleep(0.1)
                if rec.is_recording and rec.click_count() and not estado.get("avisou"):
                    estado["avisou"] = True
                    self.events.put(("aviso", None,
                                     f"gravando... {rec.click_count()} cliques (F10 encerra)"))
            rec.stop()  # desarma listeners E restaura a janela do console
            if rec.save_script(path) is None:
                self.events.put(("fim", None,
                                 "0 cliques gravados - roteiro vazio NAO salvo"))
            else:
                self.events.put(("fim", None,
                                 f"gravado: {path} ({rec.click_count()} cliques)"))

        threading.Thread(target=roda, daemon=True).start()

    def capturar_agora(self):
        """Print imediato salvo em capturas (janela nativa define a pasta)."""
        def roda():
            try:
                import datetime as _dt
                nome = "print_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S") + ".png"
                path = self.interpreter._resolve_path(nome)
                self.refs.screen.capture_to_file(path)
                self.events.put(("aviso", None, f"print salvo: {path}"))
            except Exception as e:  # noqa: BLE001 - erro vira feed, nao crash
                self.events.put(("aviso", None, f"print FALHOU: {e}"))
        threading.Thread(target=roda, daemon=True).start()

    def escolher_pasta_capturas(self):
        """Janela nativa de PASTA, aberta em capturas\\.
        capturar_tela/ler_texto com caminho relativo salvam aqui."""
        pasta = selecionar_pasta(pasta="capturas")
        if pasta:
            self.config.capture_dir = pasta
            self.lbl_capdir.config(text=self._nome_capdir())
            self._feed(f"pasta de capturas: {pasta}")

    def _nome_capdir(self):
        if os.path.isabs(self.config.capture_dir):
            return self.config.capture_dir
        return os.path.join(".", self.config.capture_dir)

    # ------------------------------------------------------------------
    # Emergencia
    # ------------------------------------------------------------------
    def _parar_tudo(self):
        self.emergency.trigger()
        self._feed("*** EMERGENCIA DISPARADA PELO PAINEL ***")

    def _reset_emergencia(self):
        self.emergency.reset()
        self._feed("emergencia resetada pelo operador")

    # ------------------------------------------------------------------
    # Feed + estatisticas
    # ------------------------------------------------------------------
    def _drain_events(self):
        try:
            while True:
                fase, ac, motivo = self.events.get_nowait()
                if fase == "fim":
                    self._feed(f"=== {motivo} ===")
                    self.lbl_status.config(text="Status: idle")
                    self._atualiza_stats()
                elif ac is None:
                    self._feed(f"* {motivo}")
                else:
                    resumo = {k: ac.get(k) for k in ("tipo", "x", "y",
                              "combinacao", "texto", "segundos") if k in ac}
                    extra = f' ("{motivo}")' if motivo and motivo != "ok" else ""
                    self._feed(f"[{fase}] {resumo}{extra}")
        except queue.Empty:
            pass
        self.root.after(200, self._drain_events)

    def _feed(self, linha: str):
        self.txt_feed.config(state="normal")
        self.txt_feed.insert("end", linha + "\n")
        self.txt_feed.see("end")
        self.txt_feed.config(state="disabled")

    def _atualiza_stats(self):
        s = self.logger.stats()
        self.lbl_stats.config(
            text=f"Total: {s['total']}  |  Permitidas: {s['allowed']}  |  "
                 f"Bloqueadas: {s['blocked']}  |  Executadas: {s['executed']}")


def main():
    root = tk.Tk()
    Dashboard(root)
    root.mainloop()


if __name__ == "__main__":
    main()

'@
    "tests\test_dashboard_ui.py" = @'
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
    "test_dashboard_ui.py",
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

    "dashboard\app.py" = "80412ADACF3BF7EA8E82C6A3FEFF9A2AC9EB09336EC4AB90E277BABD4B057486"
    "tests\test_dashboard_ui.py" = "528ED3611FB2A6AD749259E5D484B828A81DDEB6B2C4D4EE79EB65CCFA3C8F95"
    "tests\run_all.py" = "F004A19AF349E7F6A0C4A3BBB58D86145E2AD980E559A4F4450A413575509DEB"

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
