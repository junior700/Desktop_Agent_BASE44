"""
bridge.py — Ponte entre o Superagent (nuvem) e o agente desktop (PC)
================================================================================
FUTURO (Fase 3.2). Roda NO PC do professor. Duas funções:
  1. SERVIDOR HTTP local (FastAPI): expõe /status, /screenshot e /act.
     O professor acessa o chat do Superagent; a ponte pública (túnel do
     Base44 ou webhook) encaminha os comandos do agente até aqui.
  2. FILA DE COMANDOS: se a conexão com a nuvem cair, os comandos do robô
     ficam em comandos.jsonl e são aplicados em ordem (com deduplicação).

SEGURANÇA:
  - Toda ação passa pelo Executor (dry-run até aprovação explícita).
  - Token de autenticação em bridge_token.txt (gerado no primeiro boot).
  - Só aceita comandos cujo "id" ainda não foi executado (idempotência).

DEPENDÊNCIAS (PC): pip install fastapi uvicorn
"""
import json
import secrets
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

from executor import Executor
from vision import capture, read_chart_state

HERE = Path(__file__).parent
QUEUE = HERE / "comandos.jsonl"
TOKEN_FILE = HERE / "bridge_token.txt"
FILA_EXECUTADOS = HERE / "executados.jsonl"

app = FastAPI(title="Ponte WinFUT Desktop")
executor = Executor(max_contratos=1, max_acoes_min=20)

if not TOKEN_FILE.exists():
    TOKEN_FILE.write_text(secrets.token_hex(24))
TOKEN = TOKEN_FILE.read_text().strip()


def _auth(token: str):
    if not secrets.compare_digest(token, TOKEN):
        raise HTTPException(401, "Token inválido")


class Comando(BaseModel):
    id: str
    acao: str                    # "screenshot" | "ler_tela" | "ordem"
    payload: dict = {}


@app.get("/status")
def status(token: str):
    _auth(token)
    return {"ok": True, "dry_run": executor.dry_run,
            "ts": time.time(), "fila": len(QUEUE.read_text().splitlines())
            if QUEUE.exists() else 0}


@app.get("/screenshot")
def screenshot(token: str):
    """Envia a tela atual como PNG para o Superagent (visão de IA)."""
    _auth(token)
    import cv2
    ok, buf = cv2.imencode(".png", capture())
    return StreamingResponse(iter([buf.tobytes()]),
                             media_type="image/png")


@app.post("/act")
def act(cmd: Comando, token: str):
    """Recebe um comando do Superagent e o executa (se aprovado)."""
    _auth(token)
    # idempotência: nunca executa o mesmo id duas vezes
    if FILA_EXECUTADOS.exists() and cmd.id in FILA_EXECUTADOS.read_text():
        return {"ok": True, "msg": "comando já executado antes (ignorado)"}
    with FILA_EXECUTADOS.open("a") as f:
        f.write(cmd.id + "\n")
    with QUEUE.open("a") as f:
        f.write(json.dumps(cmd.model_dump(), ensure_ascii=False) + "\n")
    if cmd.acao == "ler_tela":
        return read_chart_state(capture())
    if cmd.acao == "ordem":
        executor.enviar_ordem(cmd.payload)
        return {"ok": True, "modo": "DRY-RUN" if executor.dry_run else "REAL"}
    return {"ok": True, "acao": cmd.acao}


if __name__ == "__main__":
    import uvicorn
    print("Token de acesso:", TOKEN)
    uvicorn.run(app, host="127.0.0.1", port=8765)  # só máquina local
