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


class Dashboard:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.title("Desktop Agent - Painel de Controle")
        root.geometry("880x560")

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
    def _build_ui(self):
        pad = {"padx": 6, "pady": 4}

        topo = ttk.Frame(self.root)
        topo.pack(fill="x", padx=10, pady=8)

        ttk.Button(topo, text="Abrir roteiro...",
                   command=self.abrir_roteiro).grid(row=0, column=0, **pad)
        self.lbl_arquivo = ttk.Label(topo, text="(nenhum roteiro carregado)")
        self.lbl_arquivo.grid(row=0, column=1, **pad)

        self.var_dry = tk.BooleanVar(value=True)
        ttk.Checkbutton(topo, text="Dry-run (somente simular)",
                        variable=self.var_dry).grid(row=0, column=2, **pad)

        self.btn_run = ttk.Button(topo, text="EXECUTAR",
                                  command=self.executar, style="Accent.TButton")
        self.btn_run.grid(row=0, column=3, **pad)

        ttk.Button(topo, text="PARAR TUDO (emergencia)",
                   command=self._parar_tudo).grid(row=0, column=4, **pad)
        ttk.Button(topo, text="Reset emergencia",
                   command=self._reset_emergencia).grid(row=0, column=5, **pad)

        topo2 = ttk.Frame(self.root)
        topo2.pack(fill="x", padx=10, pady=2)
        ttk.Button(topo2, text="Gravar cliques (Recorder)",
                   command=self.gravar_cliques).grid(row=0, column=0, **pad)
        ttk.Button(topo2, text="Pasta de capturas...",
                   command=self.escolher_pasta_capturas).grid(row=0, column=1, **pad)
        ttk.Button(topo2, text="Capturar tela agora",
                   command=self.capturar_agora).grid(row=0, column=2, **pad)
        self.lbl_capdir = ttk.Label(topo2, text=self._nome_capdir())
        self.lbl_capdir.grid(row=0, column=2, **pad)

        meio = ttk.Frame(self.root)
        meio.pack(fill="both", expand=True, padx=10)

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
    "test_sed_gerar_exe.py",
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
    "tests\test_smoke.py" = @'
"""
test_smoke.py - Smoke test: TODOS os .py do projeto devem compilar.

Motivacao (revisao de 25/09/2026): o dashboard/app.py foi entregue com
erro de sintaxe e nenhum teste percebeu, porque a suite nao compilava
os arquivos de UI. Este teste compila CADA .py do projeto, incluindo
dashboard/ e main.py, garantindo que nada quebre por erro de sintaxe.
"""

import os
import py_compile
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _todos_py():
    for dirpath, dirnames, filenames in os.walk(RAIZ):
        dirnames[:] = [d for d in dirnames
                       if d not in ("__pycache__", ".venv", "venv", "env",
                                    "Obsoleto", ".git", "patches")]
        for fn in filenames:
            if fn.endswith(".py"):
                yield os.path.join(dirpath, fn), fn


def run_all():
    results = []
    arquivos = sorted(_todos_py())
    results.append(("projeto tem arquivos python para compilar",
                    len(arquivos) > 0))

    for caminho, nome in arquivos:
        try:
            py_compile.compile(caminho, doraise=True)
            ok = True
        except py_compile.PyCompileError as e:
            print(f"ERRO em {nome}: {e}")
            ok = False
        results.append((f"compila: {nome}", ok))

    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("[OK]" if ok else "[ERRO]"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)

'@

}

# --- SHA-256 esperado de cada arquivo gravado (verificacao) ---
# conteudo 100% legivel acima; base64 foi descartado de proposito
# (auditoria no Bloco de Notas > blob ilegivel). O hash prova que
# o que chegou no disco e exatamente o que esta escrito aqui.
$Hashes = @{

    "dashboard\app.py" = "3D3407DC2FB5C895BB416008F2281F06454CCAB8B993F80C94B9071184BFD502"
    "tests\run_all.py" = "E693A65F99E7CE95C38E7E0C0FDACA095EA378359DF50CCCF4A25F6BA7B44BCD"
    "tests\test_smoke.py" = "846C25B3B80B4947C0641910458F8B811EBB362C67EBAE6D48ECEB0A938F0F50"

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
