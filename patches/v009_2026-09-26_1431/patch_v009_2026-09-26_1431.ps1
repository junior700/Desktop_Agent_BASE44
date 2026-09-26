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

    "agent\interpreter\interpreter.py" = @'
"""
interpreter.py - Validador e executor de roteiros JSON.

Pipeline de CADA acao:
    validar schema da acao -> GuardRails.validate() -> executar (ou logar em dry_run)

Politica fail-safe:
- Acao bloqueada pelo guardrail = roteiro ABORTADO (nao pula e segue).
- Parada de emergencia = aborto imediato.
- Acao sensivel: em modo real exige confirmacao humana (callback injetavel).
- Em dry_run nada executa; tudo e validado e logado com executed=False.

Tipos de acao suportados:
    mover_mouse, clicar, duplo_clique, clique_direito,
    tecla, digitar, aguardar, capturar_tela, ler_texto,
    se (condicional), beep, log, clicar_texto, clicar_cor,
    apagar_arquivo*, fechar_aplicacao*, executar_shell*   (* = sensivel)

Condicoes: texto_na_tela, imagem_na_tela, cor_na_tela, forma_na_tela,
sempre. clicar_texto/clicar_cor localizam o alvo NA TELA na hora e o
clique resultante e REVALIDADO pelo guardrail (nunca clica sem validacao).
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass

from agent.config import AgentConfig
from agent.safety.guardrails import GuardRails, Verdict
from agent.safety.logger import AuditLogger


# Mensagens Win32 usadas no fechamento de janela (fechar_aplicacao).
_WM_CLOSE = 0x0010
_WM_SYSCOMMAND = 0x0112
_SC_CLOSE = 0xF060


def _esperar_desaparecer(existe_fn, timeout_s, _sleep=time.sleep):
    """Espera existe_fn() virar False. True se sumiu dentro do prazo.

    _sleep e injetavel para testes (nunca dorme de verdade neles).
    """
    fim = time.monotonic() + timeout_s
    while True:
        if not existe_fn():
            return True
        if time.monotonic() >= fim:
            return False
        _sleep(0.2)


def _fechar_com_verificacao(janela, listar_fn, timeout_s=3.0,
                            _sleep=time.sleep):
    """Fecha a janela e VERIFICA que ela sumiu de verdade.

    Bug real (26/09/2026, Win PT-BR): o close() do pywinauto usa
    post_message(WM_CLOSE) - o pedido e POSTADO na fila da janela,
    nao processado a forca. Sem foco (ou minimizada), o app so
    processava o pedido quando o usuario clicava nela, e o close()
    retorna SEM erro mesmo dando timeout interno: o roteiro
    terminava ok=True com a janela ABERTA.

    Escada de fechamento (cada degrau seguido de verificacao):
      1. set_focus (restaura se minimizada + traz pra frente) e
         close (post WM_CLOSE) - o caso normal;
      2. send_message(WM_CLOSE) - SINCRONO: bloqueia ate o app
         processar a mensagem;
      3. send_message(WM_SYSCOMMAND, SC_CLOSE) - o mesmo que
         clicar no X, sem tocar mouse/teclado fisico.

    Retorna True SOMENTE quando o handle deixa de aparecer na
    enumeracao de janelas. Nunca mente sucesso; quem chama aborta
    com erro claro quando retorna False.
    """
    try:
        handle = janela.handle
    except Exception:  # noqa: BLE001 - janela ja sumiu
        return True

    def existe():
        try:
            return any(w.handle == handle for w in listar_fn())
        except Exception:  # noqa: BLE001 - sem enumerar, assume pior
            return True

    # degrau 1: foco + close
    try:
        try:
            janela.set_focus()
        except Exception:  # noqa: BLE001 - foco e bonus, nao obriga
            pass
        janela.close()
    except Exception:  # noqa: BLE001 - janelas somem no meio
        pass
    if _esperar_desaparecer(existe, timeout_s, _sleep):
        return True

    # degrau 2: WM_CLOSE sincrono
    try:
        janela.send_message(_WM_CLOSE)
    except Exception:  # noqa: BLE001
        pass
    if _esperar_desaparecer(existe, timeout_s, _sleep):
        return True

    # degrau 3: SC_CLOSE (o X por mensagem)
    try:
        janela.send_message(_WM_SYSCOMMAND, _SC_CLOSE)
    except Exception:  # noqa: BLE001
        pass
    return _esperar_desaparecer(existe, timeout_s, _sleep)

def combina_janela(alvo: str, titulo: str, exe: str) -> bool:
    """True se o alvo casa com o TITULO ou com o EXECUTAVEL da janela.

    Bug real (26/09/2026): usuario PT-BR pediu fechar 'notepad' - no
    Windows em portugues o titulo da janela e 'Sem titulo - Bloco de
    Notas' e a palavra 'notepad' so aparece no nome do EXECUTAVEL
    (NOTEPAD.EXE). Matching por titulo so falhava; agora compara
    os dois (substring, sem sensibilidade a caixa).
    """
    alvo = (alvo or "").lower().strip()
    if not alvo:
        return False
    if alvo in (titulo or "").lower():
        return True
    return alvo in (exe or "").lower()


def _exe_do_processo(pid: int) -> str:
    """Nome do executavel do processo (ex.: 'NOTEPAD.EXE').

    Retorna string vazia fora do Windows ou sem permissao - a funcao
    e so um bonus de matching, nunca pode derrubar o fluxo.
    Usa ctypes (kernel32), sem dependencia nova.
    """
    try:
        import ctypes
        from ctypes import wintypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        kernel32 = ctypes.windll.kernel32
        h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                 False, int(pid))
        if not h:
            return ""
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = wintypes.DWORD(len(buf))
            if kernel32.QueryFullProcessImageNameW(h, 0, buf,
                                                    ctypes.byref(size)):
                return os.path.basename(buf.value)
        finally:
            kernel32.CloseHandle(h)
    except Exception:  # noqa: BLE001 - fora do Windows ou pid morto
        pass
    return ""
# Campos obrigatorios por tipo de acao (validacao manual, sem dependencias).
_REQUIRED = {
    "mover_mouse": ("x", "y"),
    "clicar": ("x", "y"),
    "duplo_clique": ("x", "y"),
    "clique_direito": ("x", "y"),
    "tecla": ("combinacao",),
    "digitar": ("texto",),
    "apagar_arquivo": ("caminho",),
    "fechar_aplicacao": ("janela",),
    "executar_shell": ("comando",),
    "se": ("condicao", "entao"),
    "clicar_texto": ("texto",),
    "clicar_cor": ("cor",),
}

KNOWN_TYPES = set(_REQUIRED) | {
    "aguardar", "capturar_tela", "ler_texto", "beep", "log",
}

# Acoes que o guardrail tambem conhece mas vem de condicionais:
# (nenhuma - condicoes sao avaliadas aqui, sem passar pelo guardrail)


@dataclass
class ScriptResult:
    ok: bool
    executadas: int
    bloqueadas: int
    abort_reason: str = ""


class ScriptValidationError(Exception):
    pass


class ScriptInterpreter:
    def __init__(self, config: AgentConfig, guardrails: GuardRails,
                 logger: AuditLogger, mouse, keyboard, screen,
                 reader, matcher,
                 confirmation_fn=None, on_event=None,
                 sleep_fn=time.sleep, analyzer=None):
        """
        mouse/keyboard/screen : controllers (reais ou fakes de teste)
        reader : ScreenReader (OCR) - pode ser None (desabilita ler_texto/se texto)
        matcher : TemplateMatcher - pode ser None (desabilita se imagem)
        analyzer : ScreenAnalyzer - cor/geometria; None desabilita cor_na_tela
                  e forma_na_tela/clicar_cor
        confirmation_fn : (action) -> bool, chamada p/ acoes sensiveis em modo real
        on_event : (fase, acao, verdict) callback p/ dashboard ao vivo
        sleep_fn : injetavel p/ testes rapidos
        """
        self.config = config
        self.guardrails = guardrails
        self.logger = logger
        self.mouse = mouse
        self.keyboard = keyboard
        self.screen = screen
        self.reader = reader
        self.matcher = matcher
        self.analyzer = analyzer
        self.confirmation_fn = confirmation_fn
        self.on_event = on_event
        self._sleep = sleep_fn

    # ==================================================================
    # VALIDACAO DO ROTEIRO (antes de qualquer execucao)
    # ==================================================================
    def validate_script(self, script: dict) -> list[str]:
        """Valida a estrutura completa. Retorna lista de erros (vazia = ok)."""
        erros: list[str] = []
        if not isinstance(script, dict):
            return ["roteiro deve ser um objeto JSON"]
        if not isinstance(script.get("nome"), str) or not script["nome"].strip():
            erros.append("campo 'nome' ausente ou vazio")
        acoes = script.get("acoes")
        if not isinstance(acoes, list) or not acoes:
            erros.append("campo 'acoes' ausente, vazio ou nao e lista")
            return erros
        for i, ac in enumerate(acoes):
            erros += self._validate_action(ac, f"acao[{i}]")
        if "repetir" in script:
            r = script["repetir"]
            if not isinstance(r, int) or r < 1 or r > 100:
                erros.append("'repetir' deve ser inteiro entre 1 e 100")
        return erros

    def _validate_action(self, ac, onde: str) -> list[str]:
        erros = []
        if not isinstance(ac, dict):
            return [f"{onde}: deve ser um objeto"]
        tipo = ac.get("tipo")
        if tipo not in KNOWN_TYPES:
            return [f"{onde}: tipo desconhecido '{tipo}'"]
        for campo in _REQUIRED.get(tipo, ()):
            if campo not in ac:
                erros.append(f"{onde}: '{tipo}' exige campo '{campo}'")
        if tipo in ("mover_mouse", "clicar", "duplo_clique", "clique_direito"):
            try:
                int(ac["x"]); int(ac["y"])
            except (KeyError, TypeError, ValueError):
                erros.append(f"{onde}: coordenadas x/y devem ser inteiros")
        if tipo == "aguardar":
            s = ac.get("segundos", 1)
            if not isinstance(s, (int, float)) or not (0 <= s <= 3600):
                erros.append(f"{onde}: 'segundos' deve ser numero entre 0 e 3600")
        if tipo == "se":
            erros += self._validate_conditional(ac["condicao"], f"{onde}.condicao")
            for j, sub in enumerate(ac["entao"]):
                erros += self._validate_action(sub, f"{onde}.entao[{j}]")
            for j, sub in enumerate(ac.get("senao", [])):
                erros += self._validate_action(sub, f"{onde}.senao[{j}]")
        return erros

    def _validate_conditional(self, cond, onde: str) -> list[str]:
        if not isinstance(cond, dict):
            return [f"{onde}: deve ser um objeto"]
        t = cond.get("tipo")
        if t == "texto_na_tela":
            if not str(cond.get("texto", "")).strip():
                return [f"{onde}: condicao texto_na_tela exige 'texto'"]
        elif t == "imagem_na_tela":
            if not str(cond.get("imagem", "")).strip():
                return [f"{onde}: condicao imagem_na_tela exige 'imagem'"]
        elif t == "cor_na_tela":
            if not str(cond.get("cor", "")).strip():
                return [f"{onde}: condicao cor_na_tela exige 'cor'"]
            try:
                from agent.vision.analysis import _parse_cor
                _parse_cor(cond["cor"])
            except ValueError as e:
                return [f"{onde}: {e}"]
        elif t == "forma_na_tela":
            if not str(cond.get("forma", "")).strip():
                return [f"{onde}: condicao forma_na_tela exige 'forma'"]
            if cond["forma"].strip().lower() not in ("retangulo", "quadrado",
                                                     "triangulo", "circulo",
                                                     "elipse"):
                return [f"{onde}: forma valida: retangulo/quadrado/triangulo/circulo"]
        elif t == "sempre":
            return []
        else:
            return [f"{onde}: tipo de condicao desconhecido '{t}'"]
        return []

    # ==================================================================
    # EXECUCAO
    # ==================================================================
    def run_file(self, path: str) -> ScriptResult:
        with open(path, "r", encoding="utf-8") as f:
            script = json.load(f)
        return self.run_script(script)

    def run_script(self, script: dict) -> ScriptResult:
        erros = self.validate_script(script)
        if erros:
            raise ScriptValidationError("; ".join(erros[:5]))

        repeticoes = int(script.get("repetir", 1))
        nome = script["nome"]
        executadas = bloqueadas = 0

        for rep in range(repeticoes):
            res = self._run_actions(script["acoes"], prefixo=f"[{nome}#{rep+1}]")
            executadas += res[0]
            bloqueadas += res[1]
            if not res[2]:  # abortado
                return ScriptResult(False, executadas, bloqueadas, res[3])

        return ScriptResult(True, executadas, bloqueadas)

    # ------------------------------------------------------------------
    def _run_actions(self, acoes: list, prefixo: str = ""):
        """Roda a lista. Retorna (executadas, bloqueadas, ok, motivo_abort)."""
        executadas = bloqueadas = 0
        for ac in acoes:
            # Condicionais sao avaliadas e seus ramos executados aqui.
            if ac.get("tipo") == "se":
                ramos = self._evaluate_branches(ac)
                if ramos is None:  # erro de leitura de tela -> aborta
                    return (executadas, bloqueadas + 1, False,
                            "erro ao avaliar condicional (leitura de tela)")
                e, b, ok, motivo = self._run_actions(ramos, prefixo)
                executadas += e
                bloqueadas += b
                if not ok:
                    return (executadas, bloqueadas, False, motivo)
                continue

            verdict = self.guardrails.validate(ac)
            if not verdict.allowed:
                self._log(ac, False, False, verdict.reason)
                self._emit("bloqueada", ac, verdict)
                return (executadas, bloqueadas + 1, False, verdict.reason)

            # Acao sensivel em modo real exige confirmacao humana.
            if verdict.requires_confirmation and not self.config.dry_run:
                if self.confirmation_fn is None or not self.confirmation_fn(ac):
                    self._log(ac, False, False, "acao sensivel sem confirmacao humana")
                    return (executadas, bloqueadas + 1, False,
                            "acao sensivel negada pelo operador")

            if self.config.dry_run:
                self._log(ac, True, False, "dry-run: validada, nao executada")
                self._emit("dry_run", ac, verdict)
            else:
                try:
                    self._execute(ac)
                except Exception as e:  # noqa: BLE001 - erro vira log + aborto
                    self._log(ac, True, False, f"ERRO de execucao: {e}")
                    return (executadas, bloqueadas + 1, False, str(e))
                self._log(ac, True, True, "ok")
                self._emit("executada", ac, verdict)

            executadas += 1
            # Intervalo minimo entre acoes (humanizacao + rate limit).
            self._sleep_seguro(self.config.min_delay_between_actions_ms / 1000.0)

        return (executadas, bloqueadas, True, "")

    def _sleep_seguro(self, segundos: float) -> None:
        """
        Dorme em fatias de 0.2s, checando a emergencia a cada fatia.
        Um 'aguardar' de 3600s responde ao ESC 3x em ate 0.2s.
        """
        resta = max(0.0, float(segundos))
        while resta > 0:
            if self.guardrails.is_emergency():
                return
            fatia = min(0.2, resta)
            self._sleep(fatia)
            resta -= fatia

    # ------------------------------------------------------------------
    def _resolve_path(self, caminho: str) -> str:
        """
        Caminho relativo -> dentro de config.capture_dir (criando a pasta).
        Caminho absoluto -> usado como esta.
        """
        if os.path.isabs(caminho):
            return caminho
        pasta = self.config.capture_dir
        if not os.path.isabs(pasta):
            pasta = os.path.join(os.path.dirname(
                os.path.dirname(os.path.abspath(__file__))), "..", pasta)
            pasta = os.path.normpath(pasta)
        os.makedirs(pasta, exist_ok=True)
        return os.path.join(pasta, caminho)

    # ------------------------------------------------------------------
    def _evaluate_branches(self, ac_se) -> list | None:
        """Avalia a condicao; retorna a lista de acoes do ramo (entao/senao)."""
        cond = ac_se["condicao"]
        t = cond.get("tipo")
        if t == "sempre":
            return ac_se["entao"]
        if t == "texto_na_tela":
            if self.reader is None:
                return None
            achou = self.reader.text_on_screen(cond["texto"])
        elif t == "imagem_na_tela":
            if self.matcher is None:
                return None
            achou = self.matcher.is_on_screen(
                cond["imagem"], float(cond.get("confianca", 0.8)))
        elif t == "cor_na_tela":
            if self.analyzer is None:
                return None
            achou = self.analyzer.color_on_screen(
                cond["cor"], int(cond.get("tolerancia",
                                          self.config.color_tolerance)))
        elif t == "forma_na_tela":
            if self.analyzer is None:
                return None
            achou = self.analyzer.shape_on_screen(
                cond["forma"], int(cond.get("area_min", 200)))
        else:
            return None
        return ac_se["entao"] if achou else ac_se.get("senao", [])

    # ------------------------------------------------------------------
    def _execute(self, ac) -> None:
        """Executa a acao REAL (chegou aqui ja validada e liberada)."""
        tipo = ac["tipo"]
        if tipo == "mover_mouse":
            self.mouse.move(ac["x"], ac["y"])
        elif tipo == "clicar":
            self.mouse.click(ac["x"], ac["y"],
                             button=ac.get("botao", "left"),
                             clicks=int(ac.get("cliques", 1)))
        elif tipo == "duplo_clique":
            self.mouse.double_click(ac["x"], ac["y"])
        elif tipo == "clique_direito":
            self.mouse.right_click(ac["x"], ac["y"])
        elif tipo == "tecla":
            self.keyboard.press_combo(ac["combinacao"])
        elif tipo == "digitar":
            self.keyboard.type_text(ac["texto"])
        elif tipo == "aguardar":
            self._sleep_seguro(float(ac.get("segundos", 1)))
        elif tipo == "capturar_tela":
            self.screen.capture_to_file(
                self._resolve_path(ac.get("arquivo", "captura.png")))
        elif tipo == "ler_texto":
            if self.reader is None:
                raise RuntimeError("OCR nao configurado")
            texto = self.reader.read_screen_text()
            if ac.get("salvar_em"):
                destino = self._resolve_path(ac["salvar_em"])
                os.makedirs(os.path.dirname(destino) or ".", exist_ok=True)
                with open(destino, "w", encoding="utf-8") as f:
                    f.write(texto)
        elif tipo == "beep":
            try:
                import winsound  # Windows: beep real do hardware
                winsound.Beep(1000, 200)
            except ImportError:
                print("\a", end="", flush=True)  # fallback fora do Windows
        elif tipo == "log":
            pass  # a mensagem ja vai no audit log (snapshot)
        elif tipo == "clicar_texto":
            if self.reader is None:
                raise RuntimeError("OCR nao configurado")
            centro = self.reader.locate_text(str(ac["texto"]))
            if centro is None:
                raise RuntimeError(f"texto nao encontrado na tela: {ac['texto']!r}")
            self._clicar_validado(centro, origem="clicar_texto")
        elif tipo == "clicar_cor":
            if self.analyzer is None:
                raise RuntimeError("analise de cor nao configurada (cv2/numpy)")
            centro = self.analyzer.find_color(
                str(ac["cor"]), int(ac.get("tolerancia",
                                          self.config.color_tolerance)))
            if centro is None:
                raise RuntimeError(f"cor nao encontrada na tela: {ac['cor']!r}")
            self._clicar_validado(centro, origem="clicar_cor")
        elif tipo == "apagar_arquivo":
            self._delete_file(str(ac["caminho"]))
        elif tipo == "fechar_aplicacao":
            self._close_window(str(ac["janela"]))
        elif tipo == "executar_shell":
            self._run_shell(str(ac["comando"]))
        else:  # nunca deve acontecer (validacao ja cobriu)
            raise RuntimeError(f"tipo nao implementado: {tipo}")

    def _clicar_validado(self, centro: tuple[int, int], origem: str) -> None:
        """
        Clique com coordenada resolvida em RUNTIME (OCR/cor/geometria).
        Monta um 'clicar' sintetico e passa pelo guardrail DE NOVO:
        a regra 'toda acao passa por validate()' nunca e burlada.
        """
        sintetico = {"tipo": "clicar", "x": int(centro[0]), "y": int(centro[1]),
                     "_origem": origem}
        verdict = self.guardrails.validate(sintetico)
        if not verdict.allowed:
            raise RuntimeError(f"clique bloqueado pelo guardrail: {verdict.reason}")
        self._log(sintetico, True, True, f"{origem} -> clique validado")
        self.mouse.click(sintetico["x"], sintetico["y"])

    # ------------------------------------------------------------------
    # Acoes sensiveis - implementacoes com verificacao extra propria.
    # ------------------------------------------------------------------
    def _delete_file(self, caminho: str) -> None:
        real = os.path.abspath(caminho)
        permitido = any(real.startswith(os.path.abspath(d) + os.sep)
                        for d in self.config.file_op_allowed_dirs)
        if not permitido:
            raise PermissionError(
                f"caminho fora dos diretorios permitidos: {real}")
        if not os.path.isfile(real):
            raise FileNotFoundError(real)
        os.remove(real)

    def _close_window(self, titulo: str) -> None:
        """Fecha janela (titulo OU executavel) e VERIFICA o resultado.

        Duas passadas de busca: primeiro so VISIVEIS (evita fechar
        janela oculta antes da visivel quando ha varias), depois
        todas. O fechamento e escalado e VERIFICADO por
        _fechar_com_verificacao - so sucesso real (janela sumiu)
        conta como sucesso.
        """
        from pywinauto import Desktop  # import tardio

        def listar():
            return list(Desktop(backend="uia").windows())

        janelas = listar()
        alvo = None
        for so_visiveis in (True, False):
            for w in janelas:
                try:
                    if so_visiveis and not w.is_visible():
                        continue
                    exe = _exe_do_processo(w.process_id())
                    if combina_janela(titulo, w.window_text(), exe):
                        alvo = w
                        break
                except Exception:  # noqa: BLE001 - janelas somem no meio
                    continue
            if alvo is not None:
                break
        if alvo is None:
            raise RuntimeError(
                f"janela nao encontrada: '{titulo}'. O alvo casa por substring "
                f"com o TITULO da janela ou com o EXECUTAVEL do processo "
                f"(ex.: 'bloco de notas' ou 'notepad')")
        if not _fechar_com_verificacao(alvo, listar):
            raise RuntimeError(
                f"a janela '{titulo}' recebeu o pedido de fechamento mas "
                f"CONTINUA ABERTA. Verifique se ha um dialogo de salvar "
                f"(conteudo nao salvo) ou outra aba/tela aguardando resposta.")

    def _run_shell(self, comando: str) -> None:
        """Executa comando via subprocess (shell=False, sem elevacao)."""
        import shlex
        import subprocess
        partes = shlex.split(comando, posix=False)
        subprocess.run(partes, check=True, timeout=60,
                       capture_output=True)

    # ------------------------------------------------------------------
    def _log(self, ac, allowed: bool, executed: bool, reason: str) -> None:
        self.logger.log(ac.get("tipo", "?"), ac, allowed, executed,
                        reason, self.config.dry_run)

    def _emit(self, fase: str, ac, verdict: Verdict) -> None:
        if self.on_event is not None:
            try:
                self.on_event(fase, ac, verdict)
            except Exception:  # noqa: BLE001 - dashboard nunca derruba o agente
                pass

'@
    "tests\test_interpreter.py" = @'
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
    combina_janela, _exe_do_processo, _fechar_com_verificacao,
    _esperar_desaparecer, _WM_CLOSE, _WM_SYSCOMMAND, _SC_CLOSE)
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

    # --- 14. fechar_aplicacao: fechamento VERIFICADO (nunca mente ok) ---
    # Bug real (26/09/2026): close() do pywinauto usa post_message
    # (WM_CLOSE); janela sem foco so processava o pedido quando o
    # usuario clicava nela - roteiro terminava ok=True com a janela
    # ABERTA. Agora: set_focus + close -> WM_CLOSE sincrono ->
    # SC_CLOSE, cada degrau VERIFICADO pelo handle sumir da
    # enumeracao.

    class JanelaFake:
        """So processa WM_CLOSE quando tem foco (o bug real)."""
        def __init__(self):
            self.handle = 4242
            self.aberta = True
            self.foco = 0
            self.closes = 0
            self.msgs = []
        def set_focus(self):
            self.foco += 1
        def close(self):
            self.closes += 1
            if self.foco > 0:
                self.aberta = False
        def send_message(self, m, wp=0, lp=0):
            self.msgs.append((m, wp))
            self.aberta = False

    jf = JanelaFake()
    ok = _fechar_com_verificacao(
        jf, lambda: [jf] if jf.aberta else [],
        timeout_s=0.5, _sleep=lambda s: None)
    check("fechar: janela sem foco fecha apos set_focus (caso real)",
          ok and jf.aberta is False)
    check("fechar: caso real NAO precisa de escalada (degrau 1 basta)",
          jf.msgs == [] and jf.foco == 1)

    class JanelaTeimosa(JanelaFake):
        """Nada fecha (dialogo de salvar travado, p.ex.)."""
        def close(self):
            self.closes += 1
        def send_message(self, m, wp=0, lp=0):
            self.msgs.append((m, wp))
    jt = JanelaTeimosa()
    ok = _fechar_com_verificacao(
        jt, lambda: [jt] if jt.aberta else [],
        timeout_s=0.3, _sleep=lambda s: None)
    check("fechar: janela teimosa retorna False (NAO mente sucesso)",
          ok is False and jt.aberta is True)
    check("fechar: teimosa esgota a escada (WM_CLOSE + SC_CLOSE)",
          jt.msgs == [(_WM_CLOSE, 0), (_WM_SYSCOMMAND, _SC_CLOSE)])

    js = JanelaFake()
    js.close = lambda: None          # degrau 1 falha...
    js.send_message = lambda m, wp=0, lp=0: (  # ...WM_CLOSE sincrono resolve
        js.msgs.append((m, wp)), setattr(js, "aberta", False))
    ok = _fechar_com_verificacao(
        js, lambda: [js] if js.aberta else [],
        timeout_s=0.3, _sleep=lambda s: None)
    check("fechar: WM_CLOSE sincrono pega quando degrau 1 falha",
          ok is True and js.msgs == [(_WM_CLOSE, 0)])

    vistos = []
    existe = lambda: vistos.append(1) or len(vistos) < 2
    dormidas = []
    check("esperar_desaparecer: True quando some dentro do prazo",
          _esperar_desaparecer(existe, 1.0, _sleep=dormidas.append) is True)
    check("esperar_desaparecer: dormiu entre as checagens",
          len(dormidas) >= 1)
    check("esperar_desaparecer: False quando nao some (timeout)",
          _esperar_desaparecer(lambda: True, 0.3,
                               _sleep=lambda s: None) is False)

    class Morta:
        @property
        def handle(self):
            raise RuntimeError("janela sumiu")
    check("fechar: janela com handle morto ja e sucesso (sumiu)",
          _fechar_com_verificacao(
              Morta(), lambda: [], timeout_s=0.2,
              _sleep=lambda s: None) is True)

    jt2 = JanelaTeimosa()
    check("fechar: enumeracao quebrada NUNCA vira sucesso",
          _fechar_com_verificacao(
              jt2, lambda: (_ for _ in ()).throw(RuntimeError("boom")),
              timeout_s=0.2, _sleep=lambda s: None) is False)

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

    "agent\interpreter\interpreter.py" = "7D0511C6AA7D1FA22D00B5F2CC80EB8C718A2A286DA5CBA88C38F65ED3FAA31E"
    "tests\test_interpreter.py" = "E3356C47825769B494CA4FC1D6223FE32F0C3993207EAACDF2F0FA4FDFE1BFBC"

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
