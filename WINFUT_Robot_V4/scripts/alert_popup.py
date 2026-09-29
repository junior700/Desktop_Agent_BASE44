#!/usr/bin/env python3
"""alert_popup.py — popup nativo do Windows para os alertas do robot WINFUT.

Chamado pelo winfut_bot.py via subprocess (processo separado, não bloqueia
o loop do robot) sempre que há um alerta: sinal de compra/venda, stop, alvo,
EOD. O objetivo é mostrar na tela, em janela de diálogo do Windows, a
operação completa no estilo OCO do Profit:

    COMPRA @ 123456
      • VENDA stop-loss @ 123000
      • VENDA alvo @ 123606

Windows: MessageBox nativo (ctypes, zero dependências) com som do sistema
(beep embutido no ícone) e SYSTEMMODAL (janela fica sempre na frente).
Linux/macOS: apenas imprime no stdout (para testes fora do Windows).

Uso:  python alert_popup.py "<título>" "<mensagem multilinha>"
"""
import sys


def main() -> None:
    # modo de teste: popup OCO de exemplo (simulado, sem operação real)
    if "--test" in sys.argv:
        title = "📈 TESTE — SINAL COMPRA — Robot WINFUT (paper)"
        msg = ("TESTE DE ALERTA (simulado — não é operação real)\n\n"
               "AÇÃO: COMPRA WINFUT @ 183100\n\n"
               "OCO — VENDAS de proteção (colocar no Profit):\n"
               "   • VENDA stop-loss @ 182500\n"
               "   • VENDA alvo @ 184750  (M50 184600 + 150)\n\n"
               "Se esta janela apareceu (com som), os alertas estão OK.")
    else:
        title = sys.argv[1] if len(sys.argv) > 1 else "Robot WINFUT"
        msg = sys.argv[2] if len(sys.argv) > 2 else "(alerta sem mensagem)"

    if sys.platform == "win32":
        import ctypes

        MB_SYSTEMMODAL = 0x1000       # janela sempre no topo
        MB_ICONEXCLAMATION = 0x30     # triângulo amarelo + beep do sistema
        MB_ICONINFORMATION = 0x40     # balão azul (informativo)
        MB_SETFOREGROUND = 0x10000    # rouba o foco para a janela

        # stop = alerta mais grave; sinal = informativo
        up = title.upper()
        if "STOP" in up:
            icon = MB_ICONEXCLAMATION
        else:
            icon = MB_ICONINFORMATION
        ctypes.windll.user32.MessageBoxW(
            0, msg, title, MB_SYSTEMMODAL | MB_SETFOREGROUND | icon)
    else:
        # fora do Windows (sandbox/testes): imprime para validação
        print(f"[popup] {title}\n{msg}")


if __name__ == "__main__":
    main()
