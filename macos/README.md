# Tradutor de Vídeos — app da barra de menus

Casca Swift (SwiftUI `MenuBarExtra`, sem janela e sem ícone no Dock) que mantém o motor Python de pé
e expõe os controles do dia a dia. Requer macOS 14+ e o Xcode (ou as Command Line Tools) para compilar.

## Compilar e instalar

```sh
cd macos
./build.sh            # gera build/Tradutor de Vídeos.app (assinatura ad-hoc)
./build.sh --install  # idem e copia para ~/Applications, substituindo a cópia anterior
open ~/Applications/"Tradutor de Vídeos.app"
```

O caminho absoluto de `../engine` fica gravado no `Info.plist` (chave `TDVEngineDir`). Se o repositório
mudar de lugar, rode o `build.sh` de novo. Antes de reinstalar, feche o app pelo item **Sair**.

O motor precisa estar instalado: `cd engine && uv sync`.

## O que o app faz com o motor

- Se já houver um motor respondendo em `http://127.0.0.1:47811/health`, o app o adota: não sobe outro e
  não o encerra ao sair. Se o motor adotado sumir, o app sobe o próprio.
- Caso contrário, inicia `engine/.venv/bin/python -m dublador.server` com `/opt/homebrew/bin` e
  `/usr/local/bin` no `PATH` (ffmpeg e deno), gravando a saída em
  `~/Library/Logs/TradutorDeVideos/motor-stdout.log`.
- Se o motor cair, religa com espera crescente (1, 2, 4, 8 s). Depois de 5 quedas em 60 s desiste e
  mostra **Motor parado**; **Reiniciar motor** tenta de novo.
- Ao sair (item **Sair**, SIGTERM, SIGINT ou SIGHUP), manda SIGTERM ao motor e, se ele não sair em 3 s,
  SIGKILL. Um processo vigia (`/bin/sh`, também filho do app) encerra o motor mesmo se o app for morto
  com SIGKILL ou travar, então o motor nunca sobrevive ao app.

## Menu

| Item | O que faz |
|---|---|
| Linha de estado | `Motor ativo (v…)`, `Iniciando o motor…`, `Motor parado`, `Motor sem resposta…` ou `Motor não instalado: rode uv sync em engine/` |
| Dublagem em andamento | título, etapa com porcentagem, **Cancelar dublagem** e o tamanho da fila |
| Voz / Tradução | submenus que gravam `voice` e `translator` via `PUT /settings` |
| Três opções com marcação | `ollama_fallback`, `ollama_assist` e `use_cookies` |
| Cache | tamanho, **Limpar cache**, **Abrir pasta do cache**, **Abrir logs** |
| Reiniciar motor | reinicia o motor (inclusive um motor adotado, desde que seja mesmo o `dublador.server`) |
| Atualizar yt-dlp | roda `uv lock --upgrade-package yt-dlp` e `uv sync` em `engine/` e reinicia o motor; a saída fica em `~/Library/Logs/TradutorDeVideos/atualizar-yt-dlp.log` |
| Iniciar no login | registra o app como item de início (`SMAppService`); ative a partir da cópia em `~/Applications` |
| Sair | encerra o app e o motor que ele iniciou |

O ícone muda com o estado: onda (ocioso), onda em círculo com a porcentagem (dublando), onda cortada
(iniciando ou sem resposta) e triângulo de alerta (parado ou não instalado).

## Variáveis de ambiente (só para testes)

- `TDV_PORT`: porta do motor (padrão 47811). É repassada ao motor.
- `TDV_ENGINE_DIR`: pasta do motor, no lugar da gravada no `Info.plist`.

```sh
TDV_PORT=47812 "build/Tradutor de Vídeos.app/Contents/MacOS/TradutorBar" &
curl -s http://127.0.0.1:47812/health
pgrep -P <pid do app> -f dublador.server   # o motor; o outro filho é o vigia
```
