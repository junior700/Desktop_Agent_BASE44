"""
recorder.py — Human Recorder.

Grava ações humanas e gera um ROTEIRO JSON no mesmo schema do interpretador.

DIRETRIZ DO PROJETO: grava apenas CLIQUES (coordenada + botão) e o
INTERVALO DE TEMPO entre cliques. Movimento do mouse entre cliques
e teclas digitadas NÃO são gravados.

Saída:
    {"nome": "...", "acoes": [
        {"tipo": "clicar", "x": 100, "y": 200, "botao": "left"},
        {"tipo": "aguardar", "segundos": 1.42},
        {"tipo": "duplo_clique", "x": 300, "y": 250},
        ...
    ]}

Duplo clique: 2 cliques no mesmo ponto (tolerância 4px) em menos de
double_click_window_ms, botão esquerdo.

TECLAS (conforme diretriz do usuário):
    F12 -> INICIA a gravação de cliques (e MINIMIZA esta janela)
    F10 -> ENCERRA a gravação e finaliza (e RESTAURA esta janela)

Fluxo: arm() instala os listeners (estado "armado"); F12 liga a captura;
F10 desliga e encerra. ESC 3x dispara a emergência global a qualquer momento.
"""

from __future__ import annotations

import json
import time

from agent.config import AgentConfig


# ------------------------------------------------------------------
# Controle da janela do console (Windows).
# F12 -> minimizar a janela do script (nao atrapalha a gravacao)
# F10 -> restaurar a janela no fim
# ------------------------------------------------------------------
SW_MINIMIZE = 6
SW_RESTORE = 9


def minimize_console() -> None:
    """Minimiza a janela do console atual (nao faz nada fora do Windows)."""
    try:
        import ctypes
        hwnd = ctypes.windll.kernel32.GetConsoleWindow()
        if hwnd:
            ctypes.windll.user32.ShowWindow(hwnd, SW_MINIMIZE)
    except Exception:
        pass


def restore_console() -> None:
    """Restaura a janela do console atual (nao faz nada fora do Windows)."""
    try:
        import ctypes
        hwnd = ctypes.windll.kernel32.GetConsoleWindow()
        if hwnd:
            ctypes.windll.user32.ShowWindow(hwnd, SW_RESTORE)
    except Exception:
        pass


class HumanRecorder:
    def __init__(self, config: AgentConfig, emergency=None,
                 clock=time.monotonic, window_ctl=None):
        self.config = config
        self.emergency = emergency      # EmergencyStop compartilhado
        # controlador de janela: minimiza no F12, restaura no F10
        if window_ctl is None:
            window_ctl = type("ConsoleWindowCtl", (), {
                "minimize": staticmethod(minimize_console),
                "restore": staticmethod(restore_console),
            })()
        self.window_ctl = window_ctl
        self._clock = clock            # injetável p/ testes
        self._events: list[dict] = []  # [{"t": s, "x": int, "y": int, "botao": str}]
        self._listener = None
        self._kb_listener = None
        self._recording = False   # capturando cliques agora
        self._armed = False       # listeners instalados, aguardando F12
        self._stopped = False    # F10 apertado (ou stop manual): fim

    # ------------------------------------------------------------------
    # API de teste: injeta um clique como se viesse do mouse real.
    # ------------------------------------------------------------------
    def record_click(self, x: int, y: int, botao: str = "left",
                     t: float | None = None) -> None:
        self._events.append({"t": self._clock() if t is None else t,
                             "x": int(x), "y": int(y), "botao": botao})

    # ------------------------------------------------------------------
    # Gravação real (Windows) — pynput.
    # ------------------------------------------------------------------
    def arm(self) -> bool:
        """
        Instala os listeners e fica ARMADO: aguardando F12 para começar
        a capturar cliques e F10 para encerrar. Retorna True se armado.
        """
        if self._armed and not self._stopped:
            return True
        try:
            from pynput import mouse, keyboard  # import tardio
        except ImportError:
            return False

        self._armed = True
        self._stopped = False
        self._recording = False

        start_key = self.config.recorder_start_key  # F12
        stop_key = self.config.recorder_stop_key     # F10

        def on_click(x, y, button, pressed):
            if not self._recording or not pressed:
                return  # só captura enquanto grava; só o pressionar conta
            botao = "right" if "right" in str(button) else \
                    "middle" if "middle" in str(button) else "left"
            self.record_click(x, y, botao)

        def on_press(key):
            nome = getattr(key, "name", "")
            if nome == start_key and not self._recording:
                self._events.clear()
                self._recording = True
                # minimiza a janela do script: nao atrapalha a gravacao
                self.window_ctl.minimize()
            elif nome == stop_key:
                self._recording = False
                self.stop()  # desliga listeners; _stopped sinaliza o fim
            elif nome == "escape" and self.emergency:
                self.emergency.register_press()  # ESC 3x também vale aqui

        self._listener = mouse.Listener(on_click=on_click)
        self._listener.daemon = True
        self._listener.start()

        self._kb_listener = keyboard.Listener(on_press=on_press)
        self._kb_listener.daemon = True
        self._kb_listener.start()
        return True

    def start(self) -> bool:
        """Arma E começa a gravar imediatamente (sem aguardar F12)."""
        if not self.arm():
            return False
        self._events.clear()
        self._recording = True
        return True

    def stop(self) -> None:
        self._recording = False
        self._stopped = True
        # fim da gravacao: devolve a janela do script a tela
        try:
            self.window_ctl.restore()
        except Exception:
            pass
        if self._listener is not None:
            self._listener.stop()
            self._listener = None
        if self._kb_listener is not None:
            self._kb_listener.stop()
            self._kb_listener = None

    @property
    def is_armed(self) -> bool:
        return self._armed and not self._stopped

    @property
    def is_stopped(self) -> bool:
        return self._stopped

    @property
    def is_recording(self) -> bool:
        return self._recording

    def click_count(self) -> int:
        return len(self._events)

    # ------------------------------------------------------------------
    # Conversão eventos -> roteiro JSON
    # ------------------------------------------------------------------
    def build_script(self, nome: str = "gravacao") -> dict:
        """
        Gera o roteiro:
        - cada clique vira 'clicar'/'clique_direito'/'duplo_clique'
        - o intervalo real entre ações vira 'aguardar' (2 casas decimais)
        """
        eventos = sorted(self._events, key=lambda e: e["t"])
        janela = self.config.double_click_window_ms / 1000.0

        # 1ª passada: agrupa duplos cliques.
        # Cada entrada: (idx_inicio, idx_fim_exclusivo, acao)
        passos: list[tuple[int, int, dict]] = []
        i = 0
        while i < len(eventos):
            ev = eventos[i]
            nxt = eventos[i + 1] if i + 1 < len(eventos) else None
            if (nxt is not None
                    and ev["botao"] == nxt["botao"] == "left"
                    and nxt["t"] - ev["t"] <= janela
                    and abs(nxt["x"] - ev["x"]) <= 4
                    and abs(nxt["y"] - ev["y"]) <= 4):
                passos.append((i, i + 2,
                               {"tipo": "duplo_clique", "x": ev["x"], "y": ev["y"]}))
                i += 2
            else:
                tipo = "clique_direito" if ev["botao"] == "right" else "clicar"
                passos.append((i, i + 1,
                               {"tipo": tipo, "x": ev["x"], "y": ev["y"],
                                "botao": ev["botao"]}))
                i += 1

        # 2ª passada: insere 'aguardar' entre passos consecutivos.
        acoes: list[dict] = []
        for pos, (ini, fim, acao) in enumerate(passos):
            if pos > 0:
                delta = eventos[ini]["t"] - eventos[passos[pos - 1][1] - 1]["t"]
                acoes.append({"tipo": "aguardar", "segundos": round(max(delta, 0), 2)})
            acoes.append(acao)

        return {"nome": nome, "acoes": acoes}

    def save_script(self, path: str, nome: str = "gravacao") -> str | None:
        """
        Salva o roteiro. Retorna o caminho, ou None se NADA foi gravado
        (0 cliques: um roteiro vazio é inválido para o interpretador —
        não criar arquivo inútil é mais honesto que criar um que falha).
        """
        script = self.build_script(nome)
        if not script["acoes"]:
            return None
        with open(path, "w", encoding="utf-8") as f:
            json.dump(script, f, ensure_ascii=False, indent=2)
        return path
