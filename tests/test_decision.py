"""
test_decision.py — Testes da camada de decisão (regras + parser do LLM).
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agent.config import AgentConfig
from agent.decision.rules import RuleEngine
from agent.decision.llm_client import LLMClient


def run_all():
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731

    # --- RuleEngine ---
    regras = [
        {"se_texto_contem": "salvar", "acao": {"tipo": "tecla", "combinacao": "ctrl+s"}},
        {"se_texto_contem": "cancelar", "acao": {"tipo": "tecla", "combinacao": "esc"}},
    ]
    eng = RuleEngine(regras)
    ac, r = eng.next_action({"texto_tela": "Deseja salvar o arquivo?"})
    check("regra 'salvar' casa", ac == {"tipo": "tecla", "combinacao": "ctrl+s"})
    ac, r = eng.next_action({"texto_tela": "Cancelar operacao?"})
    check("regra 'cancelar' casa", ac["combinacao"] == "esc")
    ac, r = eng.next_action({"texto_tela": "nada relevante"})
    check("sem casa = None", ac is None)

    try:
        RuleEngine([{"sem": "acao"}])
        check("regra sem 'acao' rejeitada", False)
    except ValueError:
        check("regra sem 'acao' rejeitada", True)

    # --- Parser do LLM (sem rede: só o parse da resposta) ---
    check("parse json limpo",
          LLMClient.parse_action_json('{"tipo": "clicar", "x": 10, "y": 20}')
          == {"tipo": "clicar", "x": 10, "y": 20})
    check("parse json com markdown",
          LLMClient.parse_action_json('Acao:\n```json\n{"tipo": "digitar", "texto": "oi"}\n```')
          == {"tipo": "digitar", "texto": "oi"})
    check("resposta sem json = None",
          LLMClient.parse_action_json("desculpe, nao sei") is None)
    check("json sem 'tipo' = None",
          LLMClient.parse_action_json('{"x": 1}') is None)

    # --- Config do LLM usa defaults do AgentConfig ---
    cfg = AgentConfig()
    c = LLMClient(cfg)
    check("url default do Ollama", "11434" in c.url)
    check("modelo default", c.model == cfg.llm_model)

    return results


if __name__ == "__main__":
    rs = run_all()
    for n, ok in rs:
        print(("✅" if ok else "❌"), n)
    print(f"\n{sum(o for _, o in rs)}/{len(rs)}")
    sys.exit(0 if all(o for _, o in rs) else 1)
