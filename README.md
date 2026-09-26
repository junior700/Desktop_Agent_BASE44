# Agente Autônomo de Desktop — Windows 10/11

Agente que opera o desktop como um operador humano: cliques, teclado,
leitura de tela (OCR), roteiros JSON e gravação de ações humanas.
Python 3.12, foco total em segurança desde a fundação.

## Estrutura

```
desktop_agent/
├── agente.ps1               # menu principal (PowerShell)
├── sincronizar_github.ps1   # sincroniza a pasta raiz com o GitHub
├── main.py                  # CLI (roteiro, gravação, dashboard)
├── agent/
│   ├── config.py            # TODOS os limites de segurança
│   ├── control/             # mouse.py, keyboard.py, screen.py
│   ├── vision/              # ocr.py, template_match.py
│   ├── interpreter/         # interpreter.py (valida + executa roteiros)
│   ├── ui/                   # native_dialogs.py (janelas nativas Windows)
│   ├── recorder/            # recorder.py (Human Recorder)
│   ├── decision/            # rules.py (determinístico), llm_client.py (Ollama)
│   └── safety/              # guardrails.py, emergency_stop.py, logger.py
├── dashboard/app.py         # painel Tkinter
├── scripts/                 # roteiros de exemplo (JSON)
├── tests/                   # 89 testes (run_all.py roda tudo)
└── docs/                    # arquitetura, segurança, plano de testes
```

## Instalação (Windows 10)

1. Python 3.12 instalado (`py -3.12 --version`)
2. Tesseract OCR: https://github.com/UB-Mannheim/tesseract/wiki
3. Abra o PowerShell na pasta e rode:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\agente.ps1
   ```
4. No menu: **[1] Instalar ambiente** (cria `.venv`, instala dependências)
5. **[2] Rodar testes** — deve dar 89/89

## Uso

- **Menu**: `.\agente.ps1`

Toda escolha de arquivo/pasta abre a **janela nativa do Windows**, já
apontada para a pasta certa: roteiros e gravações em `scripts\`,
capturas em `capturas\`.
- **CLI direto**:
  - `python main.py scripts\notepad.json` — dry-run (simula, não toca em nada)
  - `python main.py scripts\notepad.json --real` — executa de verdade
  - `python main.py --gravar scripts\minha.json` — recorder: **F12 inicia**, **F10 encerra**
  - `python main.py --dashboard` — painel gráfico (tem botão **Capturar tela agora**)

### Visão programática (OCR, cor e geometria)

| Recurso | Tipo/Condição | Como usa |
|---|---|---|
| OCR: clicar em texto | ação `clicar_texto {"texto": "Salvar"}` | localiza o texto na tela e clica no centro |
| OCR: condicional | `se {"tipo": "texto_na_tela", "texto": "..."}` | executa o ramo se o texto aparecer |
| Cromática: clicar em cor | ação `clicar_cor {"cor": "#ff0000", "tolerancia": 30}` | centro do aglomerado da cor |
| Cromática: condicional | `se {"tipo": "cor_na_tela", "cor": "r,g,b ou #hex"}` | aceita `tolerancia` (default 30) |
| Geometria: condicional | `se {"tipo": "forma_na_tela", "forma": "retangulo"}` | retangulo/quadrado/triangulo/circulo, via OpenCV |
| Imagem: condicional | `se {"tipo": "imagem_na_tela", "imagem": "templates\\botao.png"}` | template matching (confiança 0.8) |

Regra de segurança: `clicar_texto`/`clicar_cor` resolvem a coordenada na
hora e o **clique resultante é revalidado pelo guardrail** (coordenada,
blacklist, rate limit). Nenhum clique escapa da validação.

### Pastas do projeto

- `scripts\` — roteiros JSON e gravações do recorder
- `capturas\` — prints de tela (ação `capturar_tela` com caminho relativo,
  e o botão "Capturar tela agora" do dashboard)
- `templates\` — imagens de referência para `imagem_na_tela`

Cor aceita `"r,g,b"` (`"255,0,0"`) ou hex (`"#ff0000"`, `"#f00"`).

## Publicar no GitHub

O projeto sincroniza com `github.com/junior700/Desktop_Agent_BASE44`:

```powershell
.\sincronizar_github.ps1
```

(ou opção `[7]` do menu). Na primeira execução ele cria o repositório local
na pasta raiz, gera o `.gitignore` (não sobe `.venv`, banco de auditoria,
capturas) e pede seu login do GitHub. **Nunca usa `--force`**: se o GitHub
tiver mudanças novas, o script baixa antes (rebase) e avisa em caso de
conflito. Repositório criado no site do GitHub (com README inicial) é
detectado automaticamente: na primeira sincronização o rebase mantém os
arquivos do projeto na frente do stub do site. Requisito: git instalado (https://git-scm.com).

### publicar_github.bat — add/commit/push com um clique

Na raiz do projeto, rode `publicar_github.bat`: mostra o que mudou,
pede confirmação, cria o commit com sua mensagem, baixa as novidades
do GitHub antes de empurrar (evita push rejeitado) e envia. Usa o
`token_github.txt` automaticamente quando existir.

### Autenticar com token pessoal (recomendado)

Para não depender de qual conta está logada no navegador: crie um arquivo
`token_github.txt` na pasta do projeto contendo apenas o token (ghp_...),
gerado em github.com/settings/tokens (escopo `repo`). O script usa esse
token automaticamente. O arquivo fica fora do git (.gitignore) e nunca é
enviado ao repositório.

## Regras de ouro

1. O agente **sempre inicia em dry-run**. Modo real exige confirmação explícita.
2. **ESC 3x** (em até 1,5s) interrompe tudo, a qualquer momento.
3. Ação bloqueada = roteiro abortado (não pula nem segue).
4. Toda ação, permitida ou bloqueada, vai para o log SQLite (`agent_audit.db`).

Veja `docs/seguranca.md` antes do primeiro modo real.
