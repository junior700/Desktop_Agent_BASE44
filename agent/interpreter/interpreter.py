"""
interpreter.py — Validador e executor de roteiros JSON.

Pipeline de CADA ação:
    validar schema da ação -> GuardRails.validate() -> executar (ou logar em dry_run)

Política fail-safe:
- Ação bloqueada pelo guardrail = roteiro ABORTADO (não pula e segue).
- Parada de emergência = aborto imediato.
- Ação sensível: em modo real exige confirmação humana (callback injetável).
- Em dry_run nada executa; tudo é validado e logado com executed=False.

Tipos de ação suportados:
    mover_mouse, clicar, duplo_clique, clique_direito,
    tecla, digitar, aguardar, capturar_tela, ler_texto,
    se (condicional), beep, log, clicar_texto, clicar_cor,
    apagar_arquivo*, fechar_aplicacao*, executar_shell*   (* = sensível)

Condições: texto_na_tela, imagem_na_tela, cor_na_tela, forma_na_tela,
sempre. clicar_texto/clicar_cor localizam o alvo NA TELA na hora e o
clique resultante é REVALIDADO pelo guardrail (nunca clica sem validação).
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass

from agent.config import AgentConfig
from agent.safety.guardrails import GuardRails, Verdict
from agent.safety.logger import AuditLogger

# Campos obrigatórios por tipo de ação (validação manual, sem dependências).
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

# Ações que o guardrail também conhece mas vêm de condicionais:
# (nenhuma — condições são avaliadas aqui, sem passar pelo guardrail)


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
        reader : ScreenReader (OCR) — pode ser None (desabilita ler_texto/se texto)
        matcher : TemplateMatcher — pode ser None (desabilita se imagem)
        analyzer : ScreenAnalyzer — cor/geometria; None desabilita cor_na_tela
                  e forma_na_tela/clicar_cor
        confirmation_fn : (action) -> bool, chamada p/ ações sensíveis em modo real
        on_event : (fase, acao, verdict) callback p/ dashboard ao vivo
        sleep_fn : injetável p/ testes rápidos
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
    # VALIDAÇÃO DO ROTEIRO (antes de qualquer execução)
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
            erros.append("campo 'acoes' ausente, vazio ou nao é lista")
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
    # EXECUÇÃO
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
            # Condicionais são avaliadas e seus ramos executados aqui.
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

            # Ação sensível em modo real exige confirmação humana.
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
                except Exception as e:  # noqa: BLE001 — erro vira log + aborto
                    self._log(ac, True, False, f"ERRO de execucao: {e}")
                    return (executadas, bloqueadas + 1, False, str(e))
                self._log(ac, True, True, "ok")
                self._emit("executada", ac, verdict)

            executadas += 1
            # Intervalo mínimo entre ações (humanização + rate limit).
            self._sleep_seguro(self.config.min_delay_between_actions_ms / 1000.0)

        return (executadas, bloqueadas, True, "")

    def _sleep_seguro(self, segundos: float) -> None:
        """
        Dorme em fatias de 0.2s, checando a emergência a cada fatia.
        Um 'aguardar' de 3600s responde ao ESC 3x em até 0.2s.
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
        Caminho absoluto -> usado como está.
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
        """Avalia a condição; retorna a lista de ações do ramo (entao/senao)."""
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
        """Executa a ação REAL (chegou aqui já validada e liberada)."""
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
            pass  # a mensagem já vai no audit log (snapshot)
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
        else:  # nunca deve acontecer (validação já cobriu)
            raise RuntimeError(f"tipo nao implementado: {tipo}")

    def _clicar_validado(self, centro: tuple[int, int], origem: str) -> None:
        """
        Clique com coordenada resolvida em RUNTIME (OCR/cor/geometria).
        Monta um 'clicar' sintético e passa pelo guardrail DE NOVO:
        a regra 'toda ação passa por validate()' nunca é burlada.
        """
        sintetico = {"tipo": "clicar", "x": int(centro[0]), "y": int(centro[1]),
                     "_origem": origem}
        verdict = self.guardrails.validate(sintetico)
        if not verdict.allowed:
            raise RuntimeError(f"clique bloqueado pelo guardrail: {verdict.reason}")
        self._log(sintetico, True, True, f"{origem} -> clique validado")
        self.mouse.click(sintetico["x"], sintetico["y"])

    # ------------------------------------------------------------------
    # Ações sensíveis — implementações com verificação extra própria.
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
        """Fecha janela por substring do título (pywinauto)."""
        from pywinauto import Desktop  # import tardio
        alvo = titulo.lower()
        for w in Desktop(backend="uia").windows():
            try:
                if alvo in w.window_text().lower():
                    w.close()
                    return
            except Exception:  # noqa: BLE001 — janelas podem sumir no meio
                continue
        raise RuntimeError(f"janela nao encontrada: '{titulo}'")

    def _run_shell(self, comando: str) -> None:
        """Executa comando via subprocess (shell=False, sem elevação)."""
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
            except Exception:  # noqa: BLE001 — dashboard nunca derruba o agente
                pass
