"""
guardrails.py — Camada de segurança do agente.

Toda ação do roteiro passa POR AQUI antes de chegar à camada de controle.
Nenhuma ação é executada sem passar por validate().

Fluxo: interpretador -> GuardRails.validate(action) -> camada de controle
Retorna um Verdict (permitida/bloqueada + motivo), e tudo é logado.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable, Optional

from agent.config import AgentConfig


@dataclass
class Verdict:
    """Resultado da avaliação de uma ação."""
    allowed: bool
    reason: str
    requires_confirmation: bool = False
    action_snapshot: dict | None = None


class GuardRails:
    """
    Validador central de ações. Instância única por processo.

    Dependência de janela ativa é injetável (active_window_title_fn) para
    permitir testes sem Windows/pywinauto.
    """

    def __init__(
        self,
        config: AgentConfig,
        active_window_title_fn: Callable[[], str] = lambda: "",
        screen_size_fn: Callable[[], tuple[int, int]] = lambda: (0, 0),
    ):
        self.config = config
        self._window_fn = active_window_title_fn
        self._screen_fn = screen_size_fn
        self._action_timestamps: list[float] = []   # janela deslizante p/ rate limit
        self._emergency: Optional["EmergencyStop"] = None
        self._screen_size: tuple[int, int] | None = None

    # ------------------------------------------------------------------
    # Emergência: o stop é injetado pelo executor na inicialização.
    # ------------------------------------------------------------------
    def attach_emergency_stop(self, emergency: "EmergencyStop") -> None:
        self._emergency = emergency

    def _screen_bounds(self) -> tuple[int, int]:
        """Lê o tamanho real da tela (com cache) e aplica o teto absoluto."""
        if self._screen_size is None:
            w, h = self._screen_fn() or (self.config.max_screen_width,
                                         self.config.max_screen_height)
            self._screen_size = (
                min(w, self.config.max_screen_width),
                min(h, self.config.max_screen_height),
            )
        return self._screen_size

    def reset_screen_cache(self) -> None:
        """Chamar se a resolução da tela mudar em runtime."""
        self._screen_size = None

    # ------------------------------------------------------------------
    # VALIDAÇÃO PRINCIPAL — única porta de entrada para execução.
    # ------------------------------------------------------------------
    def validate(self, action: dict) -> Verdict:
        snapshot = dict(action)
        tipo = str(action.get("tipo", "")).strip().lower()

        # 1) Parada de emergência tem precedência sobre tudo.
        if self._emergency is not None and self._emergency.is_triggered():
            return Verdict(False, "PARADA DE EMERGENCIA (ESC 3x)", action_snapshot=snapshot)

        # 2) Ação vazia ou sem tipo = roteiro malformado.
        if not tipo:
            return Verdict(False, "acao sem campo 'tipo'", action_snapshot=snapshot)

        # 3) Rate limiting: teto de ações por minuto.
        if not self._rate_ok():
            return Verdict(False, f"rate limit: max {self.config.max_actions_per_minute}/min",
                           action_snapshot=snapshot)

        # 4) Blacklist de janela ativa.
        title = (self._window_fn() or "").lower()
        for blocked in self.config.window_blacklist:
            if blocked in title:
                return Verdict(False, f"janela ativa na blacklist: '{blocked}'", action_snapshot=snapshot)

        # 5) Validações específicas por tipo de ação.
        if tipo in ("clicar", "mover_mouse", "duplo_clique", "clique_direito"):
            return self._validate_click(action, snapshot)
        if tipo in ("tecla", "combinacao"):
            return self._validate_keys(action, snapshot)
        if tipo in ("digitar",):
            return self._validate_typed(action, snapshot)

        # 6) Ações sensíveis: exigem confirmação humana.
        if tipo in self.config.sensitive_action_types:
            if self.config.require_confirmation_sensitive:
                return Verdict(True, "acao sensivel", requires_confirmation=True,
                               action_snapshot=snapshot)

        # Tipos conhecidos e seguros (aguardar, capturar_tela, ler_texto).
        if tipo in ("aguardar", "capturar_tela", "ler_texto", "log", "beep"):
            return Verdict(True, "ok", action_snapshot=snapshot)

        # Tipo desconhecido: recusa por padrão (fail-safe).
        return Verdict(False, f"tipo de ação desconhecido: '{tipo}'", action_snapshot=snapshot)

    # ------------------------------------------------------------------
    def _rate_ok(self) -> bool:
        now = time.monotonic()
        # Mantém apenas timestamps do último minuto.
        self._action_timestamps = [t for t in self._action_timestamps if now - t < 60]
        if len(self._action_timestamps) >= self.config.max_actions_per_minute:
            return False
        self._action_timestamps.append(now)
        return True

    def _validate_click(self, action: dict, snapshot: dict) -> Verdict:
        """Coordenada obrigatória, dentro da tela, com margem de segurança."""
        for campo in ("x", "y"):
            if campo not in action:
                return Verdict(False, f"acao '{action.get('tipo')}' sem coordenada '{campo}'",
                               action_snapshot=snapshot)
        try:
            x, y = int(action["x"]), int(action["y"])
        except (TypeError, ValueError):
            return Verdict(False, "coordenadas nao-numericas", action_snapshot=snapshot)

        w, h = self._screen_bounds()
        # Margem de 2px para não clicar em barra de borda/borda de janela.
        if not (0 <= x < w - 2 and 0 <= y < h - 2):
            return Verdict(False, f"coordenada fora da tela: ({x},{y}) vs {w}x{h}",
                           action_snapshot=snapshot)
        return Verdict(True, "ok", action_snapshot=snapshot)

    def _validate_keys(self, action: dict, snapshot: dict) -> Verdict:
        combo = str(action.get("combinacao", "")).strip().lower()
        if not combo:
            return Verdict(False, "acao de tecla sem 'combinacao'", action_snapshot=snapshot)
        for forbidden in self.config.forbidden_key_combos:
            if combo == forbidden:
                return Verdict(False, f"combo proibido: '{combo}'", action_snapshot=snapshot)
        # Normaliza espaços e ordena as teclas p/ pegar variantes ("esc+shift+ctrl")
        norm = "+".join(sorted(combo.replace(" ", "").split("+")))
        for forbidden in self.config.forbidden_key_combos:
            if norm == "+".join(sorted(forbidden.split("+"))):
                return Verdict(False, f"combo proibido (normalizado): '{combo}'",
                               action_snapshot=snapshot)
        return Verdict(True, "ok", action_snapshot=snapshot)

    def _validate_typed(self, action: dict, snapshot: dict) -> Verdict:
        texto = str(action.get("texto", ""))
        baixo = texto.lower()
        for pattern in self.config.forbidden_typed_patterns:
            # Ignora "del " dentro de palavras: exige início de palavra.
            idx = baixo.find(pattern)
            while idx != -1:
                antes_ok = idx == 0 or not baixo[idx - 1].isalnum()
                if antes_ok:
                    return Verdict(False, f"texto proibido: padrão '{pattern.strip()}'",
                                   action_snapshot=snapshot)
                idx = baixo.find(pattern, idx + 1)
        return Verdict(True, "ok", action_snapshot=snapshot)
