"""
test_interpreter.py - Testes do interpretador de roteiros.
Tudo com fakes (mouse/teclado/tela/OCR); nenhum hardware e tocado.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agent.config import AgentConfig
from agent.safety.guardrails import GuardRails
from agent.safety.emergency_stop import EmergencyStop
from agent.safety.logger import AuditLogger
from agent.interpreter.interpreter import (
    ScriptInterpreter, ScriptValidationError,
    combina_janela, _exe_do_processo)
from agent.vision.ocr import ScreenReader, FakeOCREngine


class FakeMouse:
    def __init__(self): self.calls = []
    def move(self, x, y): self.calls.append(("move", x, y))
    def click(self, x=None, y=None, button="left", clicks=1, interval_s=0):
        self.calls.append(("click", x, y, button, clicks))
    def double_click(self, x=None, y=None):
        self.calls.append(("dbl", x, y))
    def right_click(self, x=None, y=None):
        self.calls.append(("right", x, y))


class FakeKeyboard:
    def __init__(self): self.calls = []
    def type_text(self, t): self.calls.append(("type", t))
    def press_combo(self, c): self.calls.append(("combo", c))


class FakeScreen:
    def __init__(self): self.calls = []
    def capture(self): self.calls.append("capture"); return "IMG"
    def capture_to_file(self, p): self.calls.append(("save", p)); return "IMG"


class FakeMatcher:
    def __init__(self, achado=False): self.achado = achado
    def is_on_screen(self, path, conf=0.8): return self.achado


def make_interp(texto_tela="", imagem_achada=False, confirmadas=None,
                **cfg_over):
    cfg = AgentConfig(**cfg_over)
    mouse, kb, screen = FakeMouse(), FakeKeyboard(), FakeScreen()
    reader = ScreenReader(FakeScreen(), FakeOCREngine(texto_tela))
    matcher = FakeMatcher(imagem_achada)
    log = AuditLogger(tempfile.mktemp(suffix=".db"))
    guard = GuardRails(cfg, screen_size_fn=lambda: (1920, 1080))
    em = EmergencyStop(presses_required=3, window_s=1.5, test_mode=True)
    guard.attach_emergency_stop(em)

    confirm_fn = None
    if confirmadas is not None:
        confirm_fn = lambda ac: ac.get("tipo") in confirmadas  # noqa: E731

    itp = ScriptInterpreter(cfg, guard, log, mouse, kb, screen,
                            reader, matcher,
                            confirmation_fn=confirm_fn,
                            on_event=None,
                            sleep_fn=lambda s: None)
    return itp, mouse, kb, screen, log, em, guard


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # --- 1. Validacao de roteiro ---
    itp, *_ = make_interp()
    e = itp.validate_script({"nome": "ok", "acoes": [{"tipo": "aguardar", "segundos": 1}]})
    check("roteiro valido sem erros", e == [])
    e = itp.validate_script({"nome": "x", "acoes": [{"tipo": "clicar"}]})
    check("clicar sem x/y rejeitado", any("x" in x for x in e))
    e = itp.validate_script({"nome": "x", "acoes": [{"tipo": "voar"}]})
    check("tipo desconhecido rejeitado", any("voar" in x for x in e))
    e = itp.validate_script({"nome": "x", "acoes": [{"tipo": "se",
            "condicao": {"tipo": "texto_na_tela", "texto": "a"},
            "entao": [{"tipo": "clicar", "x": 1}]}]})
    check("condicional com sub-acao invalida rejeitada", len(e) > 0)
    e = itp.validate_script({"nome": "x", "acoes": [{"tipo": "aguardar"}]})
    check("aguardar sem segundos usa default 1s (valido)", e == [])

    # --- 2. Dry-run: valida e loga, NAO executa ---
    itp, mouse, kb, screen, log, *_ = make_interp()
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar", "x": 100, "y": 100},
        {"tipo": "digitar", "texto": "oi"},
    ]})
    check("dry-run conclui ok", res.ok)
    check("dry-run NAO toca no mouse", mouse.calls == [])
    check("dry-run NAO digita", kb.calls == [])
    check("dry-run loga 2 validadas", log.stats()["allowed"] == 2)
    check("dry-run loga 0 executadas", log.stats()["executed"] == 0)

    # --- 3. Modo real: executa de fato (fakes) ---
    itp, mouse, kb, screen, log, *_ = make_interp(dry_run=False)
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar", "x": 50, "y": 60},
        {"tipo": "duplo_clique", "x": 10, "y": 20},
        {"tipo": "digitar", "texto": "ola"},
        {"tipo": "tecla", "combinacao": "ctrl+s"},
        {"tipo": "aguardar", "segundos": 0},
        {"tipo": "capturar_tela", "arquivo": "x.png"},
    ]})
    check("modo real conclui ok", res.ok)
    check("clique executado", mouse.calls[0] == ("click", 50, 60, "left", 1))
    check("duplo clique executado", ("dbl", 10, 20) in mouse.calls)
    check("texto digitado", ("type", "ola") in kb.calls)
    check("combo executado", ("combo", "ctrl+s") in kb.calls)
    salvas = [c[1] for c in screen.calls if c != "capture" and c[0] == "save"]
    check("captura salva (caminho resolvido no capture_dir)",
          len(salvas) == 1
          and os.path.basename(salvas[0]) == "x.png"
          and salvas[0].replace("\\", "/").endswith("capturas/x.png"))
    check("log registra executadas", log.stats()["executed"] == 6)

    # --- 4. Acao bloqueada ABORTA o roteiro ---
    itp, mouse, *_ = make_interp(dry_run=False)
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar", "x": 99999, "y": 10},   # fora da tela
        {"tipo": "digitar", "texto": "nunca chega"},
    ]})
    check("roteiro abortado na 1a bloqueada", not res.ok and res.bloqueadas == 1)
    check("acao seguinte NUNCA executa", mouse.calls == [] and
          itp.keyboard.calls == [])

    # --- 5. Condicionais: texto na tela ---
    itp, mouse, kb, *_ = make_interp(texto_tela="Clique aqui p/ salvar",
                                     dry_run=False)
    res = itp.run_script({"nome": "t", "acoes": [{
        "tipo": "se",
        "condicao": {"tipo": "texto_na_tela", "texto": "salvar"},
        "entao": [{"tipo": "digitar", "texto": "ACHOU"}],
        "senao": [{"tipo": "digitar", "texto": "NAO"}],
    }]})
    check("condicional verdadeira roda 'entao'",
          ("type", "ACHOU") in kb.calls and ("type", "NAO") not in kb.calls)

    itp2, _, kb2, *_ = make_interp(texto_tela="outra coisa", dry_run=False)
    itp2.run_script({"nome": "t", "acoes": [{
        "tipo": "se",
        "condicao": {"tipo": "texto_na_tela", "texto": "salvar"},
        "entao": [{"tipo": "digitar", "texto": "ACHOU"}],
        "senao": [{"tipo": "digitar", "texto": "NAO"}],
    }]})
    check("condicional falsa roda 'senao'", ("type", "NAO") in kb2.calls)

    # --- 6. Condicionais: imagem na tela ---
    itp, _, kb, *_ = make_interp(imagem_achada=True, dry_run=False)
    res = itp.run_script({"nome": "t", "acoes": [{
        "tipo": "se",
        "condicao": {"tipo": "imagem_na_tela", "imagem": "btn.png"},
        "entao": [{"tipo": "digitar", "texto": "IMG_OK"}],
        "senao": [],
    }]})
    check("condicional por imagem funciona", ("type", "IMG_OK") in kb.calls)

    # --- 7. Acao sensivel: sem confirmacao = aborta (modo real) ---
    with tempfile.TemporaryDirectory() as tmp:
        cfg_dir = os.path.join(tmp, "liberado")
        os.makedirs(cfg_dir)
        alvo = os.path.join(cfg_dir, "lixo.txt")
        with open(alvo, "w") as f:
            f.write("x")
        itp, *_ = make_interp(dry_run=False, file_op_allowed_dirs=[cfg_dir])
        res = itp.run_script({"nome": "t", "acoes": [
            {"tipo": "apagar_arquivo", "caminho": alvo},
        ]})
        check("sensivel SEM confirmacao aborta", not res.ok)
        check("arquivo intacto", os.path.exists(alvo))

        # com confirmacao aprovada: executa
        itp, *_ = make_interp(dry_run=False, file_op_allowed_dirs=[cfg_dir],
                              confirmadas={"apagar_arquivo"})
        res = itp.run_script({"nome": "t", "acoes": [
            {"tipo": "apagar_arquivo", "caminho": alvo},
        ]})
        check("sensivel COM confirmacao apaga", res.ok and not os.path.exists(alvo))

        # fora dos diretorios permitidos: recusa mesmo com confirmacao
        itp, *_ = make_interp(dry_run=False, file_op_allowed_dirs=[cfg_dir],
                              confirmadas={"apagar_arquivo"})
        res = itp.run_script({"nome": "t", "acoes": [
            {"tipo": "apagar_arquivo", "caminho": os.path.join(tmp, "fora.txt")},
        ]})
        check("apagar fora do dir permitido recusado", not res.ok)

    # --- 8. apagar_arquivo em dry_run: nunca apaga ---
    itp, *_ = make_interp(dry_run=True, file_op_allowed_dirs=["C:/x"])
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "apagar_arquivo", "caminho": "C:/x/y.txt"},
    ]})
    check("dry-run nao apaga nada", res.ok and res.executadas == 1 and
          res.bloqueadas == 0)

    # --- 9. Emergencia no meio do roteiro ---
    itp, mouse, kb, _scr, log, em, _grd = make_interp(dry_run=False)
    def on_event(fase, ac, v):
        if fase == "executada" and ac.get("tipo") == "digitar":
            em.trigger()  # emergencia dispara no meio
    itp.on_event = on_event
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "digitar", "texto": "primeira"},
        {"tipo": "digitar", "texto": "segunda"},  # nunca executa
    ]})
    check("emergencia aborta roteiro", not res.ok and "EMERGENCIA" in res.abort_reason)
    check("segunda acao bloqueada", res.bloqueadas == 1)

    # --- 10. repetir N vezes ---
    itp, mouse, kb, *_ = make_interp(dry_run=False)
    res = itp.run_script({"nome": "t", "repetir": 3, "acoes": [
        {"tipo": "clicar", "x": 1, "y": 1},
    ]})
    check("repetir 3x executa 3 cliques", len(mouse.calls) == 3 and res.executadas == 3)

    # --- 11. Caminhos relativos de captura caem em capture_dir ---
    with tempfile.TemporaryDirectory() as capdir:
        itp, mouse, kb, screen, log, em, guard = make_interp(
            dry_run=False, capture_dir=capdir)
        res = itp.run_script({"nome": "t", "acoes": [
            {"tipo": "capturar_tela", "arquivo": "x.png"},
            {"tipo": "ler_texto", "salvar_em": "texto.txt"},
        ]})
        check("capturar_tela relativo resolve em capture_dir",
              ("save", os.path.join(capdir, "x.png")) in screen.calls)
        check("ler_texto relativo salva dentro do capture_dir",
              os.path.isfile(os.path.join(capdir, "texto.txt")))

    # caminho ABSOLUTO nao e redirecionado
    arq_abs = os.path.join(tempfile.mkdtemp(), "abs.png")
    itp2, *_ = make_interp(dry_run=False)
    itp2.run_script({"nome": "t", "acoes": [
        {"tipo": "capturar_tela", "arquivo": arq_abs},
    ]})
    check("capturar_tela absoluto usado como esta",
          ("save", arq_abs) in itp2.screen.calls)

    # --- 12. Roteiro invalido levanta ScriptValidationError ---
    itp, *_ = make_interp()
    try:
        itp.run_script({"nome": "t", "acoes": [{"tipo": "voar"}]})
        check("roteiro invalido levanta excecao", False)
    except ScriptValidationError:
        check("roteiro invalido levanta excecao", True)

    # --- 13. Matching de janela: TITULO ou EXECUTAVEL ---
    # Bug real (26/09/2026): 'notepad' nao casa com o titulo PT-BR
    # 'Sem titulo - Bloco de Notas' - a palavra so existe no
    # executavel (NOTEPAD.EXE).
    check("janela: 'notepad' casa via EXECUTAVEL (caso real PT-BR)",
          combina_janela("notepad", "Sem titulo - Bloco de Notas",
                         "NOTEPAD.EXE") is True)
    check("janela: titulo so (comportamento antigo) mantido",
          combina_janela("bloco de notas",
                         "Sem titulo - Bloco de Notas", "") is True)
    check("janela: 'notepad' casa com titulo EN",
          combina_janela("notepad", "Untitled - Notepad", "") is True)
    check("janela: alvo inexistente NAO casa",
          combina_janela("calculadora", "Sem titulo - Bloco de Notas",
                         "NOTEPAD.EXE") is False)
    check("janela: caixa alta ignora",
          combina_janela("NOTEPAD", "Sem titulo - Bloco de Notas",
                         "notepad.exe") is True)
    check("janela: alvo vazio NUNCA casa (nao fecha janela errada)",
          combina_janela("", "qualquer", "NOTEPAD.EXE") is False)
    check("janela: espacos nas bordas do alvo sao ignorados",
          combina_janela("  notepad  ", "Sem titulo - Bloco de Notas",
                         "NOTEPAD.EXE") is True)
    check("_exe_do_processo fora do Windows retorna '' (nao explode)",
          _exe_do_processo(999999) == "")

    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("[OK]" if ok else "[ERRO]"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)
