"""
app.py — Dashboard Tkinter do agente de desktop.

Funcionalidades:
- Carregar roteiro via seletor de arquivos (File Explorer)
- Executar roteiro com modo dry-run (default LIGADO) ou real
- Feed ao vivo das ações (executada/bloqueada/dry_run)
- Estatísticas do audit log (total/permitidas/bloqueadas/executadas)
- Confirmação de ações sensíveis (janela modal)
- Botão de PARADA DE EMERGÊNCIA e reset (ESC 3x também funciona)

O roteiro roda numa THREAD separada; a UI nunca trava.
Eventos chegam à UI via fila (thread-safe).
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
        root.title("Desktop Agent — Painel de Controle")
        root.geometry("880x560")

        self.config = AgentConfig()
        self.config.validate()
        self.emergency = EmergencyStop(
            presses_required=self.config.emergency_esc_presses,
            window_s=self.config.emergency_window_s)
        self.emergency.start()
        self.logger = AuditLogger(self.config.audit_db_path)

        # Stack ÚNICA compartilhada com o CLI (agent/runtime.py)
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

        ttk.Button(topo, text="PARAR TUDO (emergência)",
                   command=self._parar_tudo).grid(row=0, column=4, **pad)
        ttk.Button(topo, text="Reset emergência",
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

        ttk.Label(meio, text="Feed de execução:").pack(anchor="w")
        self.txt_feed = tk.Text(meio, height=16, state="disabled",
                                font=("Consolas", 10))
        self.txt_feed.pack(fill="both", expand=True)

        baixo = ttk.Frame(self.root)
        baixo.pack(fill="x", padx=10, pady=8)
        self.lbl_stats = ttk.Label(baixo, text="—")
        self.lbl_stats.pack(anchor="w")
        self.lbl_status = ttk.Label(baixo, text="Status: idle")
        self.lbl_status.pack(anchor="e")
        self._atualiza_stats()

    # ------------------------------------------------------------------
    def abrir_roteiro(self):
        # Janela nativa do Windows, já aberta em scripts\
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
            messagebox.showwarning("Ocupado", "Um roteiro já está em execução.")
            return
        if self.emergency.is_triggered():
            messagebox.showerror("Emergência ativa",
                                "Reset a emergência antes de executar.")
            return

        modo_real = not self.var_dry.get()
        if modo_real and not messagebox.askyesno(
                "CONFIRMAÇÃO",
                "Executar em modo REAL (mouse/teclado serão controlados)?\n\n"
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
            except Exception as e:  # noqa: BLE001 — erro vira feed, não crash
                msg = f"FALHOU: {e}"
            self.events.put(("fim", None, msg))

        self.runner_thread = threading.Thread(target=roda, daemon=True)
        self.runner_thread.start()
        self.lbl_status.config(text="Status: executando...")

    def _confirmar_sensivel(self, ac) -> bool:
        """Janela modal p/ ação sensível; timeout = negada (fail-safe)."""
        res = {"ok": False}
        ev = threading.Event()

        def pergunta():
            res["ok"] = messagebox.askyesno(
                "AÇÃO SENSÍVEL",
                f"Acao: {ac.get('tipo')}\n{ac}\n\nAprovar execução?")
            ev.set()
        self.root.after(0, pergunta)
        ev.wait(timeout=self.config.confirmation_timeout_s)
        return res["ok"]

    # ------------------------------------------------------------------
    # Recorder + pasta de capturas (janelas nativas do Windows)
    # ------------------------------------------------------------------
    def gravar_cliques(self):
        """Grava cliques humanos; saiída escolhida em janela nativa
        já aberta em scripts\\. F12 encerra a gravação."""
        if self.runner_thread and self.runner_thread.is_alive():
            messagebox.showwarning("Ocupado", "Aguarde a execução atual terminar.")
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
                                 "0 cliques gravados — roteiro vazio NAO salvo"))
            else:
                self.events.put(("fim", None,
                                 f"gravado: {path} ({rec.click_count()} cliques)"))

        threading.Thread(target=roda, daemon=True).start()

    def capturar_agora(self):
        """Print imediato salvo em capturas\ (janela nativa define a pasta)."""
        def roda():
            try:
                import datetime as _dt
                nome = "print_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S") + ".png"
                path = self.interpreter._resolve_path(nome)
                self.refs.screen.capture_to_file(path)
                self.events.put(("aviso", None, f"print salvo: {path}"))
            except Exception as e:  # noqa: BLE001 — erro vira feed, não crash
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
    # Emergência
    # ------------------------------------------------------------------
    def _parar_tudo(self):
        self.emergency.trigger()
        self._feed("*** EMERGENCIA DISPARADA PELO PAINEL ***")

    def _reset_emergencia(self):
        self.emergency.reset()
        self._feed("emergencia resetada pelo operador")

    # ------------------------------------------------------------------
    # Feed + estatísticas
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
