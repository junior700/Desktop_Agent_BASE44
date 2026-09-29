#!/usr/bin/env python3
"""ps_bridge.py — ponte entre o dashboard PowerShell (.ps1) e o banco SQLite
do robot de paper trading. Chamado pelo dashboard_robo.ps1 com um comando:

    python scripts/ps_bridge.py trades     # últimas 15 operações
    python scripts/ps_bridge.py open      # posições abertas agora
    python scripts/ps_bridge.py status    # resumo do paper (win/loss/pts/R$)
    python scripts/ps_bridge.py alerts    # últimos 25 alertas

Paths relativos à RAIZ do projeto (mesma convenção do winfut_bot.py):
    data/winfut/paper_trades.sqlite
    data/winfut/alerts.log
"""
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent   # raiz do projeto
DATA = ROOT / "data" / "winfut"
DB = DATA / "paper_trades.sqlite"
ALERTS = DATA / "alerts.log"


def _con() -> sqlite3.Connection:
    if not DB.exists():
        print(f"(banco ainda nao existe: {DB})")
        sys.exit(0)
    return sqlite3.connect(DB)


def _cols(con: sqlite3.Connection, table: str) -> list:
    return [r[1] for r in con.execute(f"PRAGMA table_info({table})")]


def cmd_trades(limit: int = 15) -> None:
    con = _con()
    rows = con.execute(
        "SELECT entry_time, side, entry, exit_time, exit, reason, pnl_pts, pnl_brl "
        "FROM trades ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    if not rows:
        print("(nenhuma operacao registrada ainda)")
        return
    print(f"{'ENTRADA':<17}{'LADO':<7}{'PRECO':>9}  {'SAIDA':<17}{'EXIT':>9}"
          f"  {'MOTIVO':<10}{'PTS':>8}  {'R$':>9}")
    for t in rows:
        side = (t[1] or "long")[:5]
        print(f"{t[0]:<17}{side:<7}{t[2]:>9.0f}  {str(t[3] or ''):<17}"
              f"{(t[4] or 0):>9.0f}  {str(t[5] or ''):<10}"
              f"{t[6]:>+8.0f}  {t[7]:>+9.2f}")


def cmd_open() -> None:
    con = _con()
    rows = con.execute(
        "SELECT entry_time, side, entry, stop, target_ini, status "
        "FROM trades WHERE status='aberto' ORDER BY id DESC").fetchall()
    if not rows:
        print("(sem posicoes abertas)")
        return
    for t in rows:
        side = (t[1] or "long")[:6]
        print(f"ABERTA {side:<7} desde {t[0]} | entrada {t[2]:.0f} | "
              f"stop {t[3]:.0f} | alvo {t[4]:.0f}")


def cmd_status() -> None:
    con = _con()
    tot = con.execute("SELECT COUNT(*) FROM trades").fetchone()[0]
    if tot == 0:
        print("(sem historico: nenhuma operacao registrada)")
        return
    abertas = con.execute(
        "SELECT COUNT(*) FROM trades WHERE status='aberto'").fetchone()[0]
    fechadas = con.execute(
        "SELECT COUNT(*) FROM trades WHERE status!='aberto'").fetchone()[0]
    wins = con.execute(
        "SELECT COUNT(*) FROM trades WHERE pnl_pts>0 AND status!='aberto'").fetchone()[0]
    pts = con.execute(
        "SELECT COALESCE(SUM(pnl_pts),0) FROM trades WHERE status!='aberto'").fetchone()[0]
    brl = con.execute(
        "SELECT COALESCE(SUM(pnl_brl),0) FROM trades WHERE status!='aberto'").fetchone()[0]
    print(f"Operacoes fechadas: {fechadas} | abertas: {abertas} | win rate: "
          f"{100*wins/max(fechadas,1):.0f}%")
    print(f"Resultado acumulado: {pts:+.0f} pts | {brl:+.2f} R$")


def cmd_alerts(limit: int = 25) -> None:
    if not ALERTS.exists():
        print("(arquivo de alertas ainda nao existe)")
        return
    lines = ALERTS.read_text(errors="replace").splitlines()
    for ln in lines[-limit:]:
        print(ln)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    {"trades": cmd_trades, "open": cmd_open,
     "status": cmd_status, "alerts": cmd_alerts}.get(cmd, cmd_status)()
