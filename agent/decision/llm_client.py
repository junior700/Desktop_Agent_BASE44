"""
llm_client.py — Camada de decisão via LLM (opcional, compatível com Ollama).

A IA externa gera AÇÕES no mesmo formato dos roteiros; cada ação
retornada é validada pelo guardrail antes de qualquer execução.
Se a resposta vier malformada ou for bloqueada, NADA executa.
"""

from __future__ import annotations

import json
import re

from agent.config import AgentConfig


class LLMClient:
    def __init__(self, config: AgentConfig, url: str | None = None,
                 model: str | None = None):
        self.config = config
        self.url = url or config.llm_url
        self.model = model or config.llm_model

    def ask(self, prompt: str, system: str = "") -> str:
        """Chamada CRUD /api/chat do Ollama. Retorna o texto da resposta."""
        import urllib.request
        payload = json.dumps({
            "model": self.model,
            "messages": ([{"role": "system", "content": system}] if system else [])
                        + [{"role": "user", "content": prompt}],
            "stream": False,
        }).encode("utf-8")
        req = urllib.request.Request(
            self.url, data=payload,
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.config.llm_timeout_s) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data.get("message", {}).get("content", "")

    def next_action(self, contexto: dict):
        """
        Pede UMA próxima ação à IA, em JSON.
        Retorna dict da ação ou None se a resposta não for parseável.
        Quem chama é responsável por passar a ação pelo guardrail.
        """
        prompt = (
            "Voce controla um agente de desktop. Responda APENAS com um JSON "
            "de uma unica acao, sem texto extra. Tipos validos: clicar, "
            "duplo_clique, clique_direito, mover_mouse, tecla, digitar, "
            "aguardar, capturar_tela, ler_texto. "
            f"Contexto da tela: {json.dumps(contexto, ensure_ascii=False)}"
        )
        resposta = self.ask(prompt, system=(
            "Responda sempre com um objeto JSON valido de uma acao. "
            "Nada de markdown, nada de explicacao."))
        return self.parse_action_json(resposta)

    @staticmethod
    def parse_action_json(texto: str):
        """Extrai o 1º objeto JSON da resposta (tolera ```json ...```)."""
        m = re.search(r"\{.*\}", texto, re.DOTALL)
        if not m:
            return None
        try:
            obj = json.loads(m.group(0))
        except json.JSONDecodeError:
            return None
        return obj if isinstance(obj, dict) and "tipo" in obj else None
