"""
test_sincronizar_token.py - Testes do manejo do token_github.txt
no sincronizar_github.ps1.

Motivacao (bug real 26/09/2026, v3.3 do projeto): o script procurava
apenas o nome EXATO token_github.txt. Com o Explorer em
"ocultar extensoes conhecidas", o arquivo real criado pelo usuario
era token_github.txt.txt - o script nao achava e caia na credencial
do Windows (403). Pior: o .gitignore antigo so ignorava
token_github.txt, entao o arquivo com extensao DUPLICADA seria
commitado - vazamento de credencial para o GitHub.

Nao da para executar PowerShell no sandbox de testes; as
checagens sao estaticas sobre o conteudo do .ps1 (mesma
estrategia do test_sed_gerar_exe.py com o SED).
"""

import os
import sys

PS1 = os.path.join(os.path.dirname(__file__), "..",
                   "sincronizar_github.ps1")


def _texto():
    """Le o sincronizar_github.ps1 como ASCII (regra do projeto)."""
    with open(PS1, encoding="ascii") as f:
        return f.read()


def run_all():
    """Roda todas as validacoes; retorna [(nome, ok), ...]."""
    results = []
    check = lambda n, c: results.append((n, bool(c)))  # noqa: E731
    t = _texto()

    # --- auto-cura: busca por PADRAO, nao nome exato ---
    check("token: busca por padrao token_github*.txt",
          '-Filter "token_github*.txt"' in t)
    check("token: Get-ChildItem com -File (so arquivos)",
          "Get-ChildItem" in t and " -File " in t)
    check("token: alternativa exclui o nome exato (nao le 2x)",
          "$_.FullName -ne $TokenFile" in t)
    check("token: nome exato continua sendo a 1a tentativa",
          'Test-Path $TokenFile' in t and
          '$TokenFile = Join-Path $PSScriptRoot "token_github.txt"' in t)
    check("token: aviso mostra o arquivo usado",
          "Token encontrado em: $($alt.FullName)" in t)

    # --- leitura robusta (funcao unificada) ---
    check("token: funcao Ler-Token unificada (1 ponto de leitura)",
          "function Ler-Token([string]$caminho)" in t)
    check("token: trim remove BOM, espacos, quebras e aspas",
          "[char]0xFEFF" in t and chr(34) in t and chr(39) in t)
    # --- .gitignore cobre a extensao duplicada ---
    check("gitignore: lista nova inclui token_github*.txt",
          '"Obsoleto/", "token_github.txt", "token_github*.txt"' in t)
    check("gitignore: .gitignore EXISTENTE recebe o padrao se faltar",
          '-notlike "*token_github*.txt*"' in t and "AppendAllText" in t)

    # --- guarda de desrastreio (token commitado por engano) ---
    check("seguranca: detecta token rastreado (git ls-files)",
          "git ls-files" in t and '-like "token_github*"' in t)
    check("seguranca: desrastreia com git rm --cached",
          "git rm --cached" in t)
    check("seguranca: orienta REGENERAR o token no GitHub",
          "github.com/settings/tokens" in t)

    # --- regressoes das regras do projeto ---
    check("saida: pausa no fim preservada (Read-Host)",
          "Read-Host" in t)
    dados = open(PS1, "rb").read()
    check("script 100% ASCII (sem byte nao-ASCII)",
          all(b < 128 for b in dados))
    dica = "dir token_github*" in t
    check("mensagem antiga mantida: dica 'dir token_github*'",
          dica)

    # --- v011: fluxo de sincronizacao (mensagens circulares do usuario) ---
    check("enviar: integra o remoto antes do push (git rebase origin/main)",
          "git rebase origin/main" in t)
    check("enviar: conflito no rebase -> aborta e sugere 4/5",
          "git rebase --abort" in t and "CONFLITO ao integrar" in t)
    check("opcao 4: forca segura documentada (--force-with-lease)",
          "git push --force-with-lease" in t)
    check("opcao 5: reset para o remoto (git reset --hard origin/main)",
          "git reset --hard origin/main" in t)
    check("opcao 5: exige confirmacao antes do reset",
          "Confirmar reset? [s/N]" in t)
    check("menu: agora tem 5 opcoes (4 FORCAR / 5 RESET)",
          "[4] FORCAR" in t and "[5] RESET" in t)
    check("fetch: erro NAO e engolido (2>&1 capturado)",
          "2>&1 | Out-String" in t and "--quiet" not in t.split("function Garantir-Fetch")[1].split("function")[0])
    check("seguranca: saidas de git SANITIZADAS (token nunca aparece)",
          'x-access-token:***@' in t)
    check("seguranca: detecta token em COMMITS do historico local",
          'git log --all --oneline -- "token_github*"' in t)
    check("gitignore: checagem agora e LITERAL (bug da v010 corrigido)",
          '-notlike "*token_github*.txt*"' in t)

    return results


if __name__ == "__main__":
    rs = run_all()
    for nome, ok in rs:
        print(("  [OK] " if ok else "  [FALHOU] ") + nome)
    falhas = sum(1 for _, ok in rs if not ok)
    print(f"\n{len(rs) - falhas}/{len(rs)} checagens ok")
    sys.exit(1 if falhas else 0)
