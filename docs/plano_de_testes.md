# Plano de Testes — Agente de Desktop

## Parte 1 — Testes automatizados (rodam em qualquer máquina)

Comando: `python tests/run_all.py` (ou opção [2] do agente.ps1)
Resultado esperado: **89/89**.

| Suíte | Cobre | Testes |
|---|---|---|
| test_guardrails.py | blacklist, coordenadas, combos, texto proibido, rate limit, emergência, logger | 25 |
| test_control.py | cliques, teleporte, combos, digitação humanizada (com fakes) | 9 |
| test_interpreter.py | validação de schema, dry-run, modo real, aborto em bloqueio, condicionais, ações sensíveis, emergência no meio, repetir | 31 |
| test_recorder.py | cliques→roteiro, intervalos, duplo clique, janela configurável, ordenação | 14 |
| test_decision.py | regras determinísticas, parser do LLM, defaults | 10 |

Critério de sucesso: 89/89 sem exceções.

## Parte 2 — Testes de campo (SÓ na sua máquina Windows 10)

Estes exigem hardware real e não podem ser validados no sandbox.

### 2.1 Infraestrutura
| # | Cenário | Passos | Sucesso |
|---|---|---|---|
| C1 | Instalação | agente.ps1 → [1] | .venv criado sem erro |
| C2 | Tesseract | rodar C6 abaixo | OCR lê texto da tela |
| C3 | Testes locais | agente.ps1 → [2] | 89/89 |

### 2.2 Captura e OCR
| # | Cenário | Passos | Sucesso |
|---|---|---|---|
| C4 | Screenshot | roteiro com `capturar_tela` em --real | PNG salvo com a tela atual |
| C5 | Template matching | capturar um botão, mandar `imagem_na_tela` com ele | condição retorna verdadeira |
| C6 | OCR | abrir Bloco de Notas com "teste123", roteiro com `ler_texto` | arquivo contém "teste123" |

### 2.3 Controle de verdade (mouse/teclado)
| # | Cenário | Passos | Sucesso |
|---|---|---|---|
| C7 | Roteiro notepad | `scripts\notepad.json` --real | notepad abre, digita, captura e fecha (confirma fechar) |
| C8 | Cliques | roteiro com `clicar` num botão conhecido (ex.: Calculadora) | clique no alvo certo |
| C9 | Emergência real | durante C7, apertar ESC 3x | agente para na hora; log mostra motivo EMERGENCIA |
| C10 | Failsafe pyautogui | durante modo real, jogar mouse no canto (0,0) | pyautogui aborta |

### 2.4 Human Recorder
| # | Cenário | Passos | Sucesso |
|---|---|---|---|
| C11 | Gravação | `main.py --gravar scripts\teste.json`, apertar **F12**, clicar 3 lugares, apertar **F10** | roteiro com 3 cliques + intervalos reais |
| C12 | Reprodução | rodar o roteiro gravado em dry-run, depois --real | cliques nos mesmos lugares, mesmos intervalos |
| C12b | Teclas do recorder | armado, apertar F12 → clicar → F10 | F12 começa a capturar, F10 encerra e salva |

### 2.5 Painel
| # | Cenário | Passos | Sucesso |
|---|---|---|---|
| C13 | Dashboard | `main.py --dashboard` | janela abre, feed ao vivo |
| C14 | Confirmação sensível | C13 + roteiro com fechar_aplicacao em modo real | modal pergunta; "Não" aborta |
| C15 | Janelas nativas | menu [3], [5] e botões do painel | janela do File Explorer abre JÁ em scripts\ / capturas\ |
| C16 | Sync GitHub | git instalado + opção [7] do menu → opção 1 (Enviar) | primeira execução cria repo local, .gitignore, pede login e publica no GitHub |
| C17 | Sync sem perda | mudar um arquivo no GitHub (site) + mudar outro local → opção [3] | baixa por rebase e envia; conflito real mostra instruções de resolução |

## Ordem recomendada de execução
C1 → C3 → C4 → C6 → C7 (dry-run) → C7 (--real) → C9 → C11 → C12 → C13 → C14 → C15

Se qualquer teste falhar: copie a saída do terminal + o conteúdo do feed e
me mande aqui que eu corrijo no meu ambiente antes de você mexer de novo.
