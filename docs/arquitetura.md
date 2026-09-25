# Arquitetura — Agente de Desktop

## Diagrama de componentes

```
┌────────────────────────────────────────────────────────────┐
│                      ENTRADAS                              │
│  roteiro JSON ── main.py / agente.ps1 / dashboard (Tk)      │
│  gravação humana ── recorder.py (pynput)                    │
│  IA externa (opcional) ── llm_client.py (Ollama)           │
└──────────────┬─────────────────────────────────────────────┘
               ▼
┌────────────────────────────────────────────────────────────┐
│  INTERPRETER (interpreter.py)                               │
│  valida schema → consulta guardrails → despacha/executa    │
│  condicionais: texto_na_tela, imagem_na_tela, sempre       │
└───────┬──────────────────────────────┬─────────────────────┘
        ▼                              ▼
┌──────────────────┐        ┌──────────────────────────────┐
│  SAFETY          │        │  CONTROL                     │
│  guardrails.py   │◄───────│  mouse.py (cliques, teleporte)│
│  emergency_stop  │  tudo  │  keyboard.py (digitar, combo)│
│  logger (SQLite) │ passa  │  screen.py (captura 3 layers)│
└──────────────────┘  por   └──────────────┬───────────────┘
                      aqui                 ▼
                                  ┌──────────────────────────┐
                                  │  VISION                  │
                                  │  ocr.py (Tesseract)      │
                                  │  template_match.py (cv2) │
                                  └──────────────────────────┘
```

## Responsabilidades por módulo

| Módulo | Responsabilidade |
|---|---|
| `config.py` | Única fonte de todos os limites de segurança; valida a própria sanidade |
| `safety/guardrails.py` | Porta obrigatória: emergência → rate limit → janela → regras por tipo |
| `safety/emergency_stop.py` | Listener ESC 3x em thread própria (pynput), irreversível até reset manual |
| `safety/logger.py` | Audit log SQLite de toda ação avaliada (permitida, bloqueada, executada) |
| `control/mouse.py` | Cliques + teleporte (sem trajetória, por diretriz do usuário) |
| `control/keyboard.py` | Digitação com delays humanizados; hotkeys normalizadas |
| `control/screen.py` | Captura com fallback: pyautogui → mss → PIL.ImageGrab |
| `vision/ocr.py` | Leitura de texto (Tesseract) e localização de palavras (centro p/ clique) |
| `vision/template_match.py` | matchTemplate multiescala (0.8x–1.2x) p/ achar botões/ícones |
| `interpreter/interpreter.py` | Validação do roteiro, condicionais, execução, ações sensíveis |
| `recorder/recorder.py` | Grava cliques + intervalos reais; gera roteiro no mesmo schema. F12 inicia, F10 encerra |
| `decision/rules.py` | Decisão determinística (regras se_texto_contem → ação) |
| `decision/llm_client.py` | Decisão via Ollama; resposta parseada, e a ação passa pelos guardrails |
| `dashboard/app.py` | Tkinter: seletor de roteiro, feed ao vivo, stats, confirmação sensível, emergência |
| `ui/native_dialogs.py` | Janelas NATIVAS do Windows p/ escolher arquivo/pasta, cada uma aberta na pasta correta (scripts\, capturas\, templates\) |

## Fluxo de execução de um roteiro

1. `main.py`/painel carrega JSON e valida sanidade da configuração.
2. `ScriptInterpreter.validate_script()` checa estrutura e cada ação
   (incluindo ramos de condicionais, recursivamente).
3. Para cada ação:
   - condicionais são avaliadas (OCR/imagem da tela) e o ramo certo entra no fluxo;
   - `GuardRails.validate()` dá o veredito (permitida/bloqueada/sensível);
   - bloqueada → **roteiro aborta** (fail-safe);
   - sensível em modo real → confirmação humana obrigatória;
   - dry-run → só loga; modo real → executa via CONTROL.
4. Toda decisão vai para o audit log; o painel recebe eventos ao vivo.
5. `repetir: N` executa o roteiro N vezes (máx. 100).

## Decisões de projeto (com motivo)

- **Tkinter, não Streamlit**: offline, zero dependência, e o pywinauto não
  enxerga janelas Tkinter — o painel fica fora do alcance do robô.
- **pytesseract, não EasyOCR**: EasyOCR arrasta PyTorch (~2GB) para o projeto.
- **Import tardio em tudo de hardware**: toda a lógica é testável sem Windows
  (89 testes rodam em qualquer SO com stdlib + Pillow).
- **Injeção de dependências**: backend de mouse/teclado/tela/OCR/sleep são
  parâmetros — testes são instantâneos e determinísticos.
- **Human Recorder grava só cliques + intervalos** (diretriz do usuário):
  arquivos pequenos, reprodução fiel ao que importa.
- **Ações abstratas para coisas perigosas**: o roteiro nunca manda alt+f4
  direto; usa `fechar_aplicacao` (sensível), que o interpretador executa
  via pywinauto após aprovação. O guardrail valida semântica, não teclas.
