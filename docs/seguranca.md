# Documento de Segurança — Agente de Desktop

## 1. Guard rails implementados

| Guard rail | Onde | Efeito |
|---|---|---|
| **Dry-run por padrão** | `config.py` (dry_run=True) | Agente nasce somente-leitura; modo real exige confirmação dupla (terminal ou painel) |
| **Validação de coordenadas** | `guardrails.py` | Clique fora da tela (com margem 2px) é bloqueado |
| **Blacklist de janelas** | `config.py` | Task Manager, cmd, PowerShell, regedit, Painel de Controle, Windows Update, etc. — se a janela ativa casar, nada executa |
| **Combos proibidos** | `config.py` | ctrl+shift+esc, ctrl+alt+del, win+l, alt+f4, win — inclusive variantes reordenadas ("esc+shift+ctrl") |
| **Texto destrutivo bloqueado** | `guardrails.py` | digitar "del ", "format ", "diskpart", "taskkill", "reg delete"... (com detecção de início de palavra, sem falso positivo) |
| **Rate limit** | `guardrails.py` | Máx. 60 ações/min + intervalo mínimo de 250ms entre ações |
| **Ações sensíveis** | `config.py` | apagar_arquivo, fechar_aplicacao, executar_shell exigem confirmação humana (modal no painel / prompt no terminal) |
| **Fail-safe por tipo** | `guardrails.py` | Tipo de ação desconhecido = recusado |
| **Aborto em bloqueio** | `interpreter.py` | Qualquer ação bloqueada aborta o roteiro inteiro (não "pula e segue") |
| **Stop de emergência** | `emergency_stop.py` | ESC 3x em 1,5s trava tudo; reset só manual |
| **Failsafe do pyautogui** | `mouse.py` | FAILSAFE=True: mouse no canto superior esquerdo também aborta |
| **Prisão de diretório** | `interpreter.py` | apagar_arquivo só atua dentro de `file_op_allowed_dirs` (vazio por padrão = sempre bloqueado) |
| **Shell sem elevação** | `interpreter.py` | executar_shell usa shell=False, timeout 60s, sem privilégios |

## 2. Camadas de defesa (ordem de execução)

```
roteiro JSON
  → 1. validação de schema (estrutura, campos obrigatórios, condicionais)
  → 2. GuardRails.validate (emergência → rate limit → janela ativa → regras por tipo)
  → 3. confirmação humana (se sensível e modo real)
  → 4. execução (ou apenas log, se dry-run)
  → 5. audit log SQLite (sempre, com veredito e motivo)
```

Nenhuma ação chega ao sistema operacional sem passar pelas camadas 1–3.

## 3. Auditoria de logs

- Banco: `agent_audit.db` (SQLite), tabela `audit_log`
- Cada linha: timestamp UTC, tipo, snapshot JSON da ação, permitida?, executada?, motivo, dry_run?
- Consulta: painel (estatísticas ao vivo) ou qualquer leitor SQLite:
  ```sql
  SELECT ts, action_type, allowed, executed, reason
  FROM audit_log ORDER BY id DESC LIMIT 50;
  ```
- Recomendação: revisar eventos com `allowed=1, executed=1` após cada modo real.

## 4. Recomendações de uso seguro

1. Rode SEMPRE em dry-run primeiro; confira o feed e o log.
2. Modo real: feche programas pessoais (e-mail, banco, WhatsApp Web) que
   não façam parte da tarefa. O agente pode clicar onde a tela mandar.
3. Mantenha o painel visível durante o modo real.
4. Nunca deixe `file_op_allowed_dirs` apontando para raízes largas
   (ex.: `C:\`). Use pastas de trabalho específicas.
5. ESC 3x é o freio de mão. Use sem hesitar.
6. Guarde o Tesseract e os templates de imagem dentro do projeto; roteiros
   recebidos de IA externa devem ser revisados em dry-run antes do --real.
