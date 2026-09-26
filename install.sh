#!/usr/bin/env bash
# Instalador do Tradutor de Vídeos: confere o Mac, instala o que falta, prepara o motor, compila e instala o app
# da barra de menus e deixa a extensão do Chrome pronta para carregar. Pode rodar de novo para atualizar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Tradutor de Vídeos"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; reset=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$bold" "$1" "$reset"; }
ok() { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$1"; }
fail() { printf '  %s✗ %s%s\n' "$red" "$1" "$reset" >&2; exit 1; }

step "Conferindo o Mac"
[[ "$(uname -s)" == "Darwin" ]] || fail "O Tradutor de Vídeos só roda no macOS."
macos="$(sw_vers -productVersion)"
(( ${macos%%.*} >= 14 )) || fail "Precisa do macOS 14 (Sonoma) ou mais novo; este Mac tem o $macos."
ok "macOS $macos"
if [[ "$(uname -m)" == "arm64" ]]; then ok "Apple Silicon"; else warn "Mac Intel: funciona, mas a dublagem fica bem mais lenta."; fi

step "Ferramentas"
if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    fail "Faltam as Command Line Tools da Apple. A janela de instalação acabou de abrir: conclua e rode este script de novo."
fi
swift_major="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)"
(( ${swift_major:-0} >= 6 )) || fail "Precisa do Swift 6 (Xcode 16 ou mais novo). Atualize as Command Line Tools em Ajustes do Sistema › Geral › Atualização de Software."
ok "Swift $swift_major"
command -v brew >/dev/null 2>&1 || fail "Precisa do Homebrew: instale seguindo https://brew.sh e rode este script de novo."
for tool in ffmpeg deno uv; do
    if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else
        printf '  %sinstalando %s pelo Homebrew…%s\n' "$dim" "$tool" "$reset"
        brew install --quiet "$tool" && ok "$tool"
    fi
done
if command -v ollama >/dev/null 2>&1; then ok "Ollama (opcional) encontrado"; else
    warn "Ollama não encontrado. É opcional, mas melhora a tradução: https://ollama.com"
fi

step "Motor de dublagem"
(cd "$ROOT/engine" && uv sync --quiet)
ok "dependências do Python instaladas em engine/.venv"
printf '  %sos modelos de voz e de separação (~420 MB) baixam na primeira dublagem%s\n' "$dim" "$reset"

step "App da barra de menus"
# SIGTERM: o app fecha o motor que ele iniciou antes de sair.
if pkill -TERM -x TradutorBar 2>/dev/null; then sleep 2; ok "versão anterior encerrada"; fi
dest="/Applications"
[[ -w "$dest" ]] || { dest="$HOME/Applications"; warn "Sem permissão em /Applications; instalando em ~/Applications."; }
TDV_INSTALL_DIR="$dest" "$ROOT/macos/build.sh" --install >/dev/null 2> >(grep -v "replacing existing signature" >&2)
ok "instalado em $dest/$APP_NAME.app"
open "$dest/$APP_NAME.app"
for _ in $(seq 1 30); do curl -s -m 1 -o /dev/null http://127.0.0.1:47811/health && break; sleep 1; done
if curl -s -m 2 -o /dev/null http://127.0.0.1:47811/health; then ok "motor no ar (ícone na barra de menus)"; else
    warn "o motor ainda não respondeu; veja ~/Library/Logs/TradutorDeVideos/motor-stdout.log"
fi

step "Extensão do Chrome"
cat <<EOF
  O Chrome não deixa instalar extensões fora da loja por script. Falta só isto:
    1. Abra ${bold}chrome://extensions${reset} e ligue o ${bold}Modo do desenvolvedor${reset} (canto superior direito).
    2. Clique em ${bold}Carregar sem compactação${reset} e escolha a pasta:
       ${bold}$ROOT/extension${reset}
    3. Abra um vídeo no YouTube e clique no balão que aparece nos controles do player.
EOF
if [[ -t 0 ]] && [[ -d "/Applications/Google Chrome.app" ]]; then
    read -r -p "  Abrir a página de extensões do Chrome agora? [S/n] " answer
    if [[ ! "$answer" =~ ^[nN] ]]; then
        open -a "Google Chrome" "chrome://extensions"
        open -R "$ROOT/extension/manifest.json"
    fi
fi

printf '\n%sPronto.%s Bom proveito!\n' "$green$bold" "$reset"
