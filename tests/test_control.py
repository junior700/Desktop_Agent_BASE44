"""
test_control.py — Testes das camadas de controle (mouse/teclado) com fakes.
Nenhum hardware é tocado; o backend fake registra tudo o que foi chamado.
"""

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agent.control.mouse import MouseController
from agent.control.keyboard import KeyboardController


class FakePyAutoGUI:
    """Registra chamadas como pyautogui faria, sem tocar em hardware."""
    def __init__(self):
        self.calls = []
        self.pos = (0, 0)

    def moveTo(self, x, y):
        self.pos = (x, y)
        self.calls.append(("moveTo", x, y))

    def click(self, clicks=1, button="left", interval=0):
        self.calls.append(("click", self.pos, button, clicks))

    def press(self, key):
        self.calls.append(("press", key))

    def hotkey(self, *keys):
        self.calls.append(("hotkey", keys))

    def position(self):
        return self.pos


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # --- Mouse ---
    fake = FakePyAutoGUI()
    m = MouseController(backend=fake)
    m.move(100, 200)
    check("move teleporta para (100,200)", fake.pos == (100, 200))
    m.click(300, 400, button="right")
    check("clique direito move+clique",
          fake.calls == [("moveTo", 100, 200), ("moveTo", 300, 400),
                         ("click", (300, 400), "right", 1)])
    m.double_click(10, 20)
    check("duplo clique usa clicks=2", fake.calls[-1] == ("click", (10, 20), "left", 2))
    m.click(5, 5, interval_s=0.01)
    check("clique com intervalo nao falha", fake.calls[-1][0] == "click")

    # --- Teclado ---
    fake_kb = FakePyAutoGUI()
    sem_dormir = lambda s: None  # noqa: E731 — sleep injetado = teste instantâneo
    kb = KeyboardController(backend=fake_kb, delay_min_ms=50,
                           delay_max_ms=50, sleep_fn=sem_dormir)
    kb.type_text("abc")
    check("digita 3 chars, 1 press cada",
          fake_kb.calls == [("press", "a"), ("press", "b"), ("press", "c")])
    kb.press_combo("ctrl+s")
    check("combo duplo usa hotkey", fake_kb.calls[-1] == ("hotkey", ("ctrl", "s")))
    kb.press_combo("enter")
    check("tecla unica usa press", fake_kb.calls[-1] == ("press", "enter"))
    kb.press_combo("  ctrl +  shift  + t  ")
    check("combo com espacos e maiusculas normaliza",
          fake_kb.calls[-1] == ("hotkey", ("ctrl", "shift", "t")))

    # --- Delay humanizado respeita min/max ---
    dormidas = []
    kb2 = KeyboardController(backend=FakePyAutoGUI(), delay_min_ms=100,
                             delay_max_ms=100, sleep_fn=dormidas.append)
    kb2.type_text("xyz")
    check("3 sleeps de ~100ms entre teclas", dormidas == [0.1, 0.1, 0.1])

    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("✅" if ok else "❌"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)
