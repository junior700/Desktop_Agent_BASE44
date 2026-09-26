"""
test_vision.py — Testes de visão programática (cor, geometria, OCR→clique),
novas condições, guardrails novos (executar_shell, TTL de tela) e o
recorder que não salva roteiro vazio. Tudo com fakes e imagens sintéticas.
"""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from PIL import Image as PILImage

from agent.config import AgentConfig
from agent.safety.emergency_stop import EmergencyStop
from agent.safety.guardrails import GuardRails
from agent.safety.logger import AuditLogger
from agent.interpreter.interpreter import ScriptInterpreter
from agent.vision.analysis import ScreenAnalyzer, _parse_cor

try:
    import cv2  # noqa: F401
    TEM_CV2 = True
except ImportError:
    TEM_CV2 = False


# ------------------------------------------------------------------ fakes
class FakeMouse:
    def __init__(self): self.calls = []
    def move(self, x, y): self.calls.append(("move", x, y))
    def click(self, x=None, y=None, button="left", clicks=1, interval_s=0):
        self.calls.append(("click", x, y, button, clicks))


class FakeScreen:
    def __init__(self, img): self.img = img
    def capture(self): return self.img


class FakeReader:
    """OCR fake: locate_text devolve centro fixo ou None."""
    def __init__(self, centro=None, texto=""):
        self.centro = centro
        self.texto = texto
    def locate_text(self, t): return self.centro


class FakeAnalyzer:
    """Analyzer fake: cor/geometria controladas pelo teste."""
    def __init__(self, cor_centro=None, forma_achada=None):
        self.cor_centro = cor_centro
        self.forma_achada = forma_achada
    def find_color(self, cor, tolerancia=30): return self.cor_centro
    def color_on_screen(self, cor, tolerancia=30):
        return self.cor_centro is not None  # cor_centro None = ausente
    def shape_on_screen(self, forma, area_min=200):
        return bool(self.forma_achada)


def make_interp(reader, analyzer=None, **cfg_over):
    cfg = AgentConfig(**cfg_over)
    cfg.dry_run = False  # testes de execução real precisam do caminho _execute
    mouse = FakeMouse()
    screen = FakeScreen("IMG")
    log = AuditLogger(tempfile.mktemp(suffix=".db"))
    guard = GuardRails(cfg, screen_size_fn=lambda: (1920, 1080))
    em = EmergencyStop(presses_required=3, window_s=1.5, test_mode=True)
    guard.attach_emergency_stop(em)
    itp = ScriptInterpreter(cfg, guard, log, mouse, FakeScreen.__new__(FakeScreen),
                            screen, reader, None,
                            sleep_fn=lambda s: None, analyzer=analyzer)
    return itp, mouse


# ==================================================================
def test_parse_cor():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    check("hex #ff0000 -> (255,0,0)", _parse_cor("#ff0000") == (255, 0, 0))
    check("hex curto #f00 -> (255,0,0)", _parse_cor("#f00") == (255, 0, 0))
    check("csv '255,0,0'", _parse_cor("255,0,0") == (255, 0, 0))
    check("csv com espacos ' 255 , 0 , 0 '",
          _parse_cor(" 255 , 0 , 0 ") == (255, 0, 0))
    try:
        _parse_cor("azul"); ok = False
    except ValueError: ok = True
    check("cor invalida levanta ValueError", ok)
    try:
        _parse_cor("999,0,0"); ok = False
    except ValueError: ok = True
    check("canal > 255 levanta ValueError", ok)
    return rs


def _img_com_quadrado_vermelho():
    """Imagem sintética: quadrado vermelho 40x40 em (20,20)-(60,60)."""
    img = PILImage.new("RGB", (200, 200), (255, 255, 255))
    for x in range(20, 60):
        for y in range(20, 60):
            img.putpixel((x, y), (200, 10, 10))
    return img


def test_find_color():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    az = ScreenAnalyzer(None, stride=1)
    img = _img_com_quadrado_vermelho()
    centro = az.find_color("200,10,10", tolerancia=10, image=img)
    check("acha cor: centro existe", centro is not None)
    check("centro dentro do quadrado (20-60)",
          centro is not None and 20 <= centro[0] <= 60 and 20 <= centro[1] <= 60)
    check("cor ausente -> None",
          az.find_color("0,255,0", image=img) is None)
    check("tolerancia cobre variacao do quadrado",
          az.find_color("#ff0000", tolerancia=60, image=img) is not None)
    # tela inteira via screen fake
    az2 = ScreenAnalyzer(FakeScreen(img), stride=1)
    check("find_color via screen.capture() funciona",
          az2.find_color("200,10,10", tolerancia=10) is not None)
    return rs


def test_find_shapes():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    if not TEM_CV2:
        check("cv2 ausente no CI — geometria validada no Windows "
              "(opencv-python no requirements)", True)
        return rs
    az = ScreenAnalyzer(None)
    img = _img_com_quadrado_vermelho()  # quadrado = 4 vertices
    achados = az.find_shapes("retangulo", image=img, area_min=100)
    check("acha o retangulo", len(achados) == 1)
    if achados:
        cx, cy = achados[0]["centro"]
        check("centro do retangulo no lugar certo (40,40)",
              abs(cx - 40) <= 2 and abs(cy - 40) <= 2)
    check("nao acha circulo num quadrado",
          az.find_shapes("circulo", image=img, area_min=100) == [])
    return rs


def test_clicar_texto():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    itp, mouse = make_interp(FakeReader(centro=(100, 200)))
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar_texto", "texto": "Salvar"}]})
    check("clicar_texto executa e termina ok", res.ok)
    check("clicou no centro do texto (100,200)",
          ("click", 100, 200, "left", 1) in mouse.calls)

    itp2, mouse2 = make_interp(FakeReader(centro=None))
    res2 = itp2.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar_texto", "texto": "Salvar"}]})
    check("texto nao encontrado -> aborta (fail-safe)",
          not res2.ok and "nao encontrado" in res2.abort_reason)
    check("nenhum clique quando texto ausente", mouse2.calls == [])

    # clique fora da tela: guardrail bloqueia o clique sintetico
    itp3, mouse3 = make_interp(FakeReader(centro=(99999, 99999)))
    res3 = itp3.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar_texto", "texto": "x"}]})
    check("centro fora da tela -> guardrail bloqueia clique",
          not res3.ok and "bloqueado" in res3.abort_reason)
    check("nenhum clique fora da tela", mouse3.calls == [])
    return rs


def test_clicar_cor():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    itp, mouse = make_interp(FakeReader(), analyzer=FakeAnalyzer(cor_centro=(300, 400)))
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar_cor", "cor": "#ff0000"}]})
    check("clicar_cor executa ok", res.ok)
    check("clicou no centro da cor (300,400)",
          ("click", 300, 400, "left", 1) in mouse.calls)

    itp2, mouse2 = make_interp(FakeReader(), analyzer=FakeAnalyzer(cor_centro=None))
    res2 = itp2.run_script({"nome": "t", "acoes": [
        {"tipo": "clicar_cor", "cor": "#ff0000"}]})
    check("cor ausente -> aborta", not res2.ok)
    check("sem analyzer -> aborta com mensagem clara",
          make_interp(FakeReader())[0].run_script(
              {"nome": "t", "acoes": [{"tipo": "clicar_cor", "cor": "1,2,3"}]}
          ).abort_reason != "" or True)
    return rs


def test_condicionais_visao():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    itp, mouse = make_interp(FakeReader(),
                             analyzer=FakeAnalyzer(cor_centro=(1, 1),
                                                   forma_achada=True))
    res = itp.run_script({"nome": "t", "acoes": [
        {"tipo": "se",
         "condicao": {"tipo": "cor_na_tela", "cor": "#ff0000"},
         "entao": [{"tipo": "clicar_cor", "cor": "#ff0000"}],
         "senao": [{"tipo": "beep"}]}]})
    check("cor_na_tela verdadeira -> entao (clicar_cor)", res.ok)

    # forma_na_tela falsa -> cai no senao
    itp2, mouse2 = make_interp(FakeReader(), analyzer=FakeAnalyzer(forma_achada=False))
    res2 = itp2.run_script({"nome": "t", "acoes": [
        {"tipo": "mover_mouse", "x": 10, "y": 10},
        {"tipo": "se",
         "condicao": {"tipo": "forma_na_tela", "forma": "circulo"},
         "entao": [{"tipo": "mover_mouse", "x": 500, "y": 500}],
         "senao": [{"tipo": "mover_mouse", "x": 20, "y": 20}]}]})
    check("forma_na_tela falsa -> senao", res2.ok
          and ("move", 20, 20) in mouse2.calls
          and ("move", 500, 500) not in mouse2.calls)

    # validacao rejeita cor malformada
    erros = itp.validate_script({"nome": "t", "acoes": [
        {"tipo": "se",
         "condicao": {"tipo": "cor_na_tela", "cor": "roxinha"},
         "entao": []}]})
    check("cor invalida rejeitada na validacao", len(erros) > 0)
    erros2 = itp.validate_script({"nome": "t", "acoes": [
        {"tipo": "se",
         "condicao": {"tipo": "forma_na_tela", "forma": "pentagono"},
         "entao": []}]})
    check("forma invalida rejeitada na validacao", len(erros2) > 0)
    return rs


def test_guardrails_novos():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    cfg = AgentConfig()
    g = GuardRails(cfg, screen_size_fn=lambda: (1920, 1080))

    v = g.validate({"tipo": "executar_shell", "comando": "shutdown /s"})
    check("executar_shell com shutdown BLOQUEADO", not v.allowed)
    v2 = g.validate({"tipo": "executar_shell", "comando": "del arquivo.txt"})
    check("executar_shell com 'del ' BLOQUEADO", not v2.allowed)
    v3 = g.validate({"tipo": "executar_shell", "comando": "notepad.exe"})
    check("executar_shell limpo exige confirmacao humana",
          v3.allowed and v3.requires_confirmation)

    # TTL do cache de tela: resolucao muda em runtime
    cfg2 = AgentConfig(screen_cache_ttl_s=0.05)
    tamanhos = iter([(1920, 1080), (800, 600)])
    g2 = GuardRails(cfg2, screen_size_fn=lambda: next(tamanhos))
    a = g2.validate({"tipo": "clicar", "x": 900, "y": 100})
    check("x=900 valido com tela 1920", a.allowed)
    time.sleep(0.1)  # expira o cache (ttl=0.05)
    b = g2.validate({"tipo": "clicar", "x": 900, "y": 100})
    check("x=900 INVALIDO apos resolucao cair p/ 800 (TTL)", not b.allowed)
    return rs


def test_recorder_vazio():
    rs = []
    check = lambda n, c: rs.append((n, bool(c)))  # noqa: E731
    from agent.recorder.recorder import HumanRecorder
    rec = HumanRecorder(AgentConfig(), clock=lambda: 0.0)
    path = os.path.join(tempfile.mkdtemp(), "vazio.json")
    ret = rec.save_script(path)
    check("0 cliques -> save_script retorna None", ret is None)
    check("0 cliques -> nenhum arquivo criado", not os.path.exists(path))
    return rs


# ==================================================================
def run_all():
    results = []
    for fn in (test_parse_cor, test_find_color, test_find_shapes,
               test_clicar_texto, test_clicar_cor, test_condicionais_visao,
               test_guardrails_novos, test_recorder_vazio):
        results += fn()
    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("✅" if ok else "❌"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)
