"""
rules.py — Camada de decisão determinística (regras if/then).

Usada quando não há LLM: dado um contexto (texto lido da tela),
devolve a próxima ação. Regras são avaliadas em ordem; a primeira
que casa vence. Nenhuma ação gerada aqui escapa dos guardrails.
"""

from __future__ import annotations


class RuleEngine:
    def __init__(self, regras: list[dict]):
        """
        regras: [{"se_texto_contem": "salvar", "acao": {...}}, ...]
        A ação tem o mesmo formato dos roteiros (validada pelo guardrail depois).
        """
        for r in regras:
            if "acao" not in r:
                raise ValueError("toda regra precisa de 'acao'")
        self.regras = regras

    def next_action(self, contexto: dict):
        """
        contexto: {"texto_tela": "...", ...}
        Retorna (acao, regra_aplicada) ou (None, None) se nada casar.
        """
        texto = str(contexto.get("texto_tela", "")).lower()
        for r in self.regras:
            alvo = str(r.get("se_texto_contem", "")).lower()
            if alvo and alvo in texto:
                return r["acao"], r
        return None, None
