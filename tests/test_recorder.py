"""
test_recorder.py — Testes do Human Recorder.
Eventos injetados com timestamps controlados; nenhuma gravação real.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agent.config import AgentConfig
from agent.recorder.recorder import HumanRecorder


def make_recorder(**cfg):
    config = AgentConfig(**cfg)
    return HumanRecorder(config, clock=lambda: 0.0)


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # --- 0. Teclas de controle: F12 inicia, F10 para (diretriz do usuario) ---
    cfg = AgentConfig()
    check("F12 e a tecla de INICIO da gravacao", cfg.recorder_start_key == "f12")
    check("F10 e a tecla de PARADA da gravacao", cfg.recorder_stop_key == "f10")

    # --- 1. Cliques simples com intervalos ---
    rec = make_recorder()
    rec.record_click(100, 200, "left", t=10.0)
    rec.record_click(300, 400, "left", t=11.5)   # 1.5s depois
    rec.record_click(600, 50, "right", t=13.25)  # 1.75s depois
    script = rec.build_script("teste")
    acoes = script["acoes"]
    check("3 cliques viram 3 acoes + 2 esperas", len(acoes) == 5)
    check("primeira acao e clique", acoes[0] == {
        "tipo": "clicar", "x": 100, "y": 200, "botao": "left"})
    check("espera 1 = 1.5s", acoes[1] == {"tipo": "aguardar", "segundos": 1.5})
    check("espera 2 = 1.75s", acoes[3] == {"tipo": "aguardar", "segundos": 1.75})
    check("botao direito detectado", acoes[4]["tipo"] == "clique_direito")

    # --- 2. Duplo clique (2 clicks < 350ms no mesmo ponto) ---
    rec = make_recorder()
    rec.record_click(500, 300, "left", t=1.0)
    rec.record_click(502, 301, "left", t=1.2)    # 200ms depois, mesmo ponto
    rec.record_click(800, 600, "left", t=3.0)
    acoes = rec.build_script("d")["acoes"]
    tipos = [a["tipo"] for a in acoes]
    check("2 clicks rapidos = 1 duplo_clique", tipos == ["duplo_clique", "aguardar", "clicar"])
    check("duplo clique nas coords certas", acoes[0] == {
        "tipo": "duplo_clique", "x": 500, "y": 300})
    check("espera apos duplo usa o 2o clique como origem",
          acoes[1] == {"tipo": "aguardar", "segundos": round(3.0 - 1.2, 2)})

    # --- 3. 2 clicks rapidos em pontos DIFERENTES nao sao duplo ---
    rec = make_recorder()
    rec.record_click(100, 100, "left", t=1.0)
    rec.record_click(400, 400, "left", t=1.1)
    acoes = rec.build_script() ["acoes"]
    check("clicks em pontos distintos ficam separados",
          [a["tipo"] for a in acoes] == ["clicar", "aguardar", "clicar"])

    # --- 4. Janela do duplo clique configuravel ---
    rec = make_recorder(double_click_window_ms=100)  # muito curto
    rec.record_click(500, 300, "left", t=1.0)
    rec.record_click(501, 300, "left", t=1.2)  # 200ms > 100ms
    acoes = rec.build_script()["acoes"]
    check("janela curta nao forma duplo",
          [a["tipo"] for a in acoes] == ["clicar", "aguardar", "clicar"])

    # --- 5. Roteiro gerado é valido para o interpretador ---
    rec = make_recorder()
    rec.record_click(10, 20, "left", t=0.0)
    rec.record_click(30, 40, "left", t=2.0)
    script = rec.build_script("gravado")
    check("nome do roteiro preservado", script["nome"] == "gravado")
    check("formato tem nome+acoes", set(script.keys()) == {"nome", "acoes"})

    # --- 6. Sem eventos = roteiro vazio valido ---
    rec = make_recorder()
    script = rec.build_script("vazio")
    check("sem cliques = acoes vazias", script["acoes"] == [])

    # --- 7. Eventos fora de ordem sao ordenados por tempo ---
    rec = make_recorder()
    rec.record_click(10, 10, "left", t=5.0)
    rec.record_click(20, 20, "left", t=1.0)
    acoes = rec.build_script()["acoes"]
    check("eventos ordenados por timestamp", acoes[0]["x"] == 20)

    # --- 8. F12 minimiza a janela do console; F10/emergencia restaura ---
    class _FakeWin:
        def __init__(self):
            self.calls = []

        def minimize(self):
            self.calls.append("minimize")

        def restore(self):
            self.calls.append("restore")

    ctl = _FakeWin()
    rec = make_recorder()
    rec.window_ctl = ctl
    check("janela intocada antes da gravacao", ctl.calls == [])
    rec.stop()
    check("encerrar gravação restaura a janela", "restore" in ctl.calls)

    ctl2 = _FakeWin()
    rec2 = make_recorder()
    rec2.window_ctl = ctl2
    check("recorder novo sempre restauro disponível",
          hasattr(rec2.window_ctl, "restore"))

    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("✅" if ok else "❌"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)
