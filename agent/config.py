"""
config.py — Configuração central do agente de desktop.
TODOS os limites de segurança ficam aqui, em um único lugar, para auditoria fácil.

IMPORTANTE: o agente SEMPRE inicia em modo somente-leitura (DRY_RUN=True).
O usuário libera a execução real explicitamente pelo dashboard ou CLI.
"""

from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Janelas e processos onde o agente NUNCA pode atuar (blacklist dura).
# Comparação por substring, case-insensitive, no título da janela ativa.
# ---------------------------------------------------------------------------
WINDOW_BLACKLIST: list[str] = [
    "gerenciador de tarefas", "task manager",
    "prompt de comando", "command prompt",
    "powershell",
    "editor do registro", "registry editor", "editor de registro", "regedit",
    "gerenciador de dispositivos", "device manager",
    "segurança do windows", "windows security",
    "configurações", "windows update",
    "gerenciamento do disco", "disk management",
    "format",                        # diálogos de formatação
    "painel de controle", "control panel",
]

# Combos de tecla que o agente jamais pode enviar direto do roteiro (lowercase).
# Ações abstratas (ex.: fechar_aplicacao) podem sintetizar Alt+F4 internamente
# APÓS aprovação — o guardrail valida a ação semântica, não a tecla.
FORBIDDEN_KEY_COMBOS: list[str] = [
    "ctrl+shift+esc", "alt+f4", "win+l", "ctrl+alt+del", "win",
]

# Padrões de texto que o agente não pode digitar (comandos destrutivos).
FORBIDDEN_TYPED_PATTERNS: list[str] = [
    "format ", "del ", "erase ", "rd ", "rmdir", "rm -rf",
    "diskpart", "reg delete", "reg add", "bcdedit",
    "shutdown", "taskkill", "net user", "cipher",
    "regedit", "msconfig", "vssadmin",
]

# Ações que exigem confirmação humana explícita antes de rodar.
SENSITIVE_ACTION_TYPES: list[str] = [
    "apagar_arquivo", "fechar_aplicacao", "executar_shell",
]


@dataclass
class AgentConfig:
    # --- Modos de operação ---
    dry_run: bool = True              # True = observa e registra, NÃO executa
    require_confirmation_sensitive: bool = True

    # --- Rate limiting ---
    max_actions_per_minute: int = 60
    min_delay_between_actions_ms: int = 250

    # --- Limites de tela (teto absoluto; tamanho real lido em runtime) ---
    max_screen_width: int = 7680
    max_screen_height: int = 4320

    # --- Humanização (digitação) ---
    typing_delay_min_ms: int = 60
    typing_delay_max_ms: int = 180

    # --- Cliques (diretriz: trajetória irrelevante, só clique + intervalo) ---
    double_click_window_ms: int = 350   # 2 cliques rápidos = duplo clique

    # --- Segurança ---
    # Cache do tamanho da tela expira após N segundos (resolução muda em runtime).
    screen_cache_ttl_s: float = 30.0
    emergency_esc_presses: int = 3
    emergency_window_s: float = 1.5
    confirmation_timeout_s: int = 30
    # Diretórios onde apagar_arquivo pode atuar. VAZIO = sempre bloqueado.
    file_op_allowed_dirs: list[str] = field(default_factory=list)

    # --- Saída de capturas e imagens de referência ---
    # capturar_tela / ler_texto com caminho RELATIVO caem aqui.
    capture_dir: str = "capturas"
    # Templates (prints de botões/ícones p/ condicional imagem_na_tela).
    templates_dir: str = "templates"
    # Tolerância cromática padrão (canal 0-255) p/ cor_na_tela/clicar_cor.
    color_tolerance: int = 30

    # --- Recorder ---
    recorder_start_key: str = "f12"     # tecla que INICIA a gravação
    recorder_stop_key: str = "f10"      # tecla que ENCERRA a gravação

    # --- Camada de decisão (LLM opcional, compatível com Ollama) ---
    llm_url: str = "http://localhost:11434/api/chat"
    llm_model: str = "llama3.2"
    llm_timeout_s: int = 120

    # --- Blacklists (imutáveis em runtime) ---
    window_blacklist: list[str] = field(default_factory=lambda: list(WINDOW_BLACKLIST))
    forbidden_key_combos: list[str] = field(default_factory=lambda: list(FORBIDDEN_KEY_COMBOS))
    forbidden_typed_patterns: list[str] = field(default_factory=lambda: list(FORBIDDEN_TYPED_PATTERNS))
    sensitive_action_types: list[str] = field(default_factory=lambda: list(SENSITIVE_ACTION_TYPES))

    # --- Logging ---
    audit_db_path: str = "agent_audit.db"

    def validate(self) -> None:
        """Sanidade da configuração na inicialização."""
        if self.max_actions_per_minute < 1:
            raise ValueError("max_actions_per_minute deve ser >= 1")
        if self.typing_delay_min_ms > self.typing_delay_max_ms:
            raise ValueError("typing_delay_min_ms > max_ms")
        if self.emergency_esc_presses < 1:
            raise ValueError("emergency_esc_presses deve ser >= 1")
        if self.double_click_window_ms < 100:
            raise ValueError("double_click_window_ms muito baixo")
