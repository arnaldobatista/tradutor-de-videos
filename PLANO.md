# Tradutor de vídeos do YouTube — plano

Dublagem automática de vídeos do YouTube para pt-BR, tocando direto no player do YouTube.
Uso pessoal, sem loja, sem custo recorrente.

## Decisões (2026-09-21)

| Tema | Decisão | Observação |
|---|---|---|
| Idioma | qualquer idioma → pt-BR | assumido; configurável no menu |
| Voz (TTS) | local e grátis, via MLX | motor escolhido no spike (Kokoro × Qwen3-TTS × Chatterbox); interface plugável |
| Tradução | faixa traduzida do próprio YouTube | via yt-dlp; interface plugável; fallback futuro com Ollama |
| App macOS | casca Swift + motor Python | SwiftUI `MenuBarExtra`, sem Dock; motor FastAPI supervisionado pela casca |
| Espera | processa o vídeo inteiro + cache | API já modelada como job + manifesto para virar progressiva depois |
| Distribuição | extensão unpacked (modo desenvolvedor) | sem Chrome Web Store |

## O que mudou na implementação (2026-09-21)

Os spikes derrubaram algumas premissas do plano original. O que vale hoje:

| Tema | Plano | Como ficou | Por quê |
|---|---|---|---|
| Cookies do YouTube | não previsto | a extensão lê os cookies do `youtube.com` (`chrome.cookies`) e manda ao motor antes de cada job | sem sessão, a faixa traduzida responde HTTP 429; e o macOS bloqueia processos externos de ler a pasta do Chrome, então `--cookies-from-browser` não funciona |
| Tradução reserva | fase 5 | Ollama já entra como plano B quando o YouTube nega a faixa | sem isso o vídeo simplesmente falhava |
| Segmentação das falas | por pausa e tamanho | por frase completa: pontuação do próprio texto em português, ou restaurada pelo LLM local na transcrição automática | cortar no meio da frase deixava o TTS picotado e fazia o LLM puxar conteúdo das falas vizinhas |
| Falas longas | só acelerar | o LLM local enxuga a fala antes; depois acelera; teto rígido de atraso de 1,2 s | vídeos de fala rápida chegavam a 35 s de atraso acumulado |
| Separação de voz | RoFormer × Demucs | `htdemucs` | 6,7x tempo real no M1 Max contra 3,6x do RoFormer, com vazamento de voz equivalente em conteúdo falado |
| TTS | Kokoro × Qwen3-TTS × Chatterbox | Kokoro via ONNX (`kokoro-onnx`) | ~4x tempo real em CPU, dependências leves, 3 vozes pt-BR; a interface `TTSEngine` segue plugável |
| Paralelismo | etapas em série | separação (GPU) roda junto com falas (LLM) e voz (CPU) | corta ~30% do tempo total |
| Cache | todos os artefatos | só fundo em FLAC, nível da voz, falas e o m4a final | ~150 MB por vídeo de 20 min em vez de ~700 MB |
| Extensão | TypeScript + esbuild | JavaScript puro, sem build | carrega direto da pasta; menos peças para um projeto pessoal |
| Entrega do áudio | a decidir no spike | service worker busca em blocos (`Range`) e o content script monta um `blob:` | imune ao prompt de rede local e à CSP da página |

## Arquitetura

- **Extensão (Chrome MV3)** = controle remoto + player. Detecta o vídeo, pede a dublagem, mostra progresso, silencia o áudio original e toca o dublado em sincronia. Não processa nada.
- **App da barra de menus** = casca Swift (ícone, status, ajustes, cache, login item) que sobe e monitora o **motor Python**, que expõe uma API HTTP em `127.0.0.1` e executa o pipeline.
- Só a faixa de áudio é baixada. O vídeo continua vindo do YouTube.

Máquina alvo: M1 Max, 64 GB, macOS 27, Chrome 153. Já instalados: uv, ffmpeg, yt-dlp, deno, Xcode 27, Ollama.
O Python do sistema é 3.14 (novo demais para libs de ML): o motor fixa **Python 3.12 via uv**.

## Pipeline (motor)

1. **Baixar áudio** — yt-dlp como lib, formato `bestaudio`, convertido para WAV 44.1 kHz.
2. **Legendas** — yt-dlp, formato `json3`, duas faixas:
   - texto em pt: legenda manual pt/pt-BR se existir; senão a faixa auto-traduzida para pt;
   - faixa original (manual ou ASR), usada só para tempos e segmentação.
   - Sem nenhuma legenda: o MVP retorna erro claro ("vídeo sem legendas"). Fase 5: Whisper local + tradução por Ollama.
   - A faixa traduzida sofre rate limit (HTTP 429) com alguma frequência: retry com backoff e cache agressivo.
3. **Segmentar** — cues viram falas: junta cues consecutivos por pontuação e pausas (> 0.4 s), com teto de ~10 s por fala. Cada fala tem `inicio`, `fim` e `folga` (silêncio até a próxima).
4. **Separar voz** — RoFormer (`audio-separator` ou `mlx-audio-separator`) ou Demucs; escolhido no spike por velocidade × qualidade. Saídas: `vocals.wav` (referência de loudness, futura clonagem) e `background.flac`.
5. **Gerar voz** — uma síntese por fala, interface `TTSEngine.synthesize(texto, voz, speed) -> wav`.
6. **Ajustar tempo** — como a tradução do YouTube não controla tamanho, o encaixe é todo aqui:
   - cabe na janela (duração + folga − 0.15 s): ok;
   - estourou até 1.35x: regenera com `speed` (preferível) ou time-stretch (rubberband / `atempo`);
   - estourou mais: acelera 1.35x e empurra as falas seguintes (reflow) até reencontrar folga; atraso acumulado máximo de 2.5 s;
   - passou disso: marca a fala como "estourada" no relatório do job. Melhoria futura: encurtar só essas frases com LLM local.
7. **Mixar** — normaliza a voz nova para o mesmo LUFS da voz original, ducking leve do fundo (−2 dB) sob fala, limiter, exporta `dub.m4a` (AAC, `+faststart`).
8. **Cache** — `~/Library/Caches/TradutorDeVideos/<video_id>/` com artefatos por etapa (`source.wav`, `subs.*.json3`, `falas.json`, `vocals.wav`, `background.flac`, `tts/*.wav`, `dub.pt-BR.<voz>.m4a`, `job.json`). Etapas já concluídas não são refeitas. Limite de tamanho com LRU.

Pesos do progresso: download 5%, legendas 5%, separação 45%, TTS 35%, ajuste + mix 10%.

## API local

Bind só em `127.0.0.1:47811`.

| Rota | Função |
|---|---|
| `GET /health` | `{ok, version}` |
| `POST /jobs` `{video_id, target_lang}` | cria ou reaproveita o job (idempotente por vídeo + idioma + voz) |
| `GET /jobs/{id}` | `{status, stage, progress, error?, audio_url?, falas_estouradas?}` |
| `GET /jobs/{id}/audio` | m4a com suporte a `Range` |
| `DELETE /jobs/{id}` | cancela |
| `GET/PUT /settings` | idioma, voz, motor TTS, limite de cache |

Segurança: se a requisição trouxer header `Origin` e ele não for `chrome-extension://<id da extensão>`, responde 403. CORS liberado só para essa origem. Isso impede que um site qualquer dispare jobs.

## Extensão (MV3, TypeScript + esbuild)

- `host_permissions`: `https://www.youtube.com/*` e `http://127.0.0.1:47811/*`.
- **Service worker**: único ponto que fala com o servidor (evita o prompt de Local Network Access que o Chrome aplica a páginas públicas desde a versão 142). Polling de progresso a cada 1–2 s enquanto houver job ativo.
- **Content script**:
  - botão em `.ytp-right-controls`: ocioso → processando (%) → dublado/original;
  - silenciar original: `AudioContext.createMediaElementSource(video)` → `GainNode` (0 no modo dublado, 1 no original). O volume/mute do YouTube continua valendo e é espelhado no áudio dublado via `volumechange`;
  - sync: `play`, `pause`, `waiting`, `playing`, `seeking`, `seeked`, `ratechange`; a cada ~500 ms mede o drift: > 0.3 s dá seek, entre 0.05 e 0.3 s corrige com micro-ajuste de `playbackRate`;
  - anúncios: enquanto `.html5-video-player` tiver a classe `ad-showing`, pausa a dublagem e devolve o ganho original;
  - navegação SPA: `yt-navigate-finish` desmonta tudo e reavalia o novo vídeo; lives são ignoradas.
- **Entrega do áudio à página** (decidido no spike): (a) `<audio src="http://127.0.0.1…">` direto, mais simples e com `Range`; ou (b) service worker baixa e repassa em blocos por `Port`, o content script monta um `Blob` e toca por `blob:` URL, imune a CSP/LNA.
- Popup: liga/desliga, idioma, status do servidor.

## Casca Swift (barra de menus)

- SwiftUI `MenuBarExtra`, `LSUIElement = YES`, login item via `SMAppService`.
- `EngineSupervisor`: sobe o motor com `Process` (venv do uv), checa `/health`, reinicia se cair, encerra com SIGTERM ao sair, grava log em `~/Library/Logs/TradutorDeVideos/`.
- Menu: status do servidor, job atual e fila, idioma, voz, motor TTS, cache (tamanho, limpar, abrir pasta), logs, atualizar yt-dlp, iniciar no login, sair.

## Estrutura do repositório

```
PLANO.md
spikes/        experimentos descartáveis da fase 0
engine/        motor Python (uv, Python 3.12)
  src/dublador/
    cli.py  server.py  jobs.py  cache.py  config.py
    pipeline/  download.py  subtitles.py  segment.py  separate.py  fit.py  mix.py
    pipeline/tts/  base.py  <motor escolhido>.py
    pipeline/translate/  base.py  youtube.py
  tests/
extension/     Chrome MV3
  manifest.json
  src/content/  src/background/  src/popup/
macos/         casca Swift (Xcode)
```

## Fases

**Fase 0 — Spikes.** Pronto quando houver resposta medida para cada risco:
1. yt-dlp baixa áudio + faixa original + faixa pt de 3 vídeos de teste (legenda manual, só ASR, idioma não inglês). Anotar incidência de 429.
2. Separação: tempo e qualidade de RoFormer × Demucs num trecho de 10 min no M1 Max.
3. TTS pt-BR: Kokoro × Qwen3-TTS × Chatterbox (via `mlx-audio`) nas mesmas 10 frases; avaliar naturalidade, velocidade, estabilidade em frase longa e controle de `speed`.
4. Mini-extensão: silencia o YouTube via `AudioContext`, toca um arquivo do servidor local em sync, testa entrega (a) e (b), seek, velocidade 2x e anúncio.

**Fase 1 — Motor como CLI.** `uv run dub <url>` gera o m4a dublado e um relatório (tempo por etapa, falas estouradas). Pronto quando um vídeo de 20 min sair ouvível de ponta a ponta e a segunda execução vier do cache.

**Fase 2 — Servidor.** API acima, fila com 1 job por vez, cancelamento, checagem de origem. Pronto quando der para operar tudo por `curl`.

**Fase 3 — Extensão MVP.** Pronto quando: clico no botão, vejo o progresso, assisto dublado com seek/pause/velocidade funcionando, alterno para o original, e trocar de vídeo não deixa áudio fantasma.

**Fase 4 — Casca Swift.** Pronto quando o app inicia no login, mantém o motor de pé e todos os controles do menu funcionam.

**Fase 5 — Qualidade.** Em ordem de valor: reprodução progressiva; encurtar falas estouradas com LLM local; Whisper + Ollama para vídeos sem legenda; clonagem da voz original; múltiplos falantes; dublagem automática por canal.

## Riscos

| Risco | Mitigação |
|---|---|
| pt-BR mais longo que o original, sem controle de tamanho na tradução | encaixe por folga + `speed` + reflow; relatório de falas estouradas; LLM local depois |
| Faixa auto-traduzida com frases quebradas (vem cue a cue) | segmentação por pausa e pontuação antes do TTS |
| 429 na faixa traduzida | retry com backoff, cache, fallback Ollama na fase 5 |
| YouTube quebra o yt-dlp de tempos em tempos | item "atualizar yt-dlp" no menu |
| Local Network Access / CSP do YouTube | todo I/O com o servidor pelo service worker; spike 4 decide a entrega do áudio |
| Tempo de processamento | cache por etapa agora; progressivo na fase 5 |
| Vídeos de música | sem tratamento especial; o botão é manual, basta não usar |
