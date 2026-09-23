# Tradutor de vídeos do YouTube

Dubla vídeos do YouTube para português do Brasil e toca a dublagem no próprio player, no lugar do áudio original. Tudo roda local, sem custo por uso. Uso pessoal.

Três peças:

| Pasta | O que é |
|---|---|
| `engine/` | Motor em Python: baixa o áudio, pega as legendas, remove a voz original, gera a voz em português, encaixa no tempo e mixa. Expõe uma API em `127.0.0.1:47811`. |
| `extension/` | Extensão do Chrome: botão no player, envio dos seus cookies do YouTube ao motor, áudio dublado em sincronia com o vídeo. |
| `macos/` | App da barra de menus (Swift): mantém o motor de pé e dá os controles (voz, tradução, cache, logs, iniciar no login). |

O plano, as decisões e os riscos estão em [PLANO.md](PLANO.md).

## Instalar

Pré-requisitos (Homebrew): `ffmpeg`, `deno`, `uv`. Opcional, mas recomendado: [Ollama](https://ollama.com) com um modelo instruct.

```bash
cd engine && uv sync
```

```bash
cd macos && ./build.sh --install
```

Abra o app **Tradutor de Vídeos** (na pasta Aplicativos, `/Applications`). O ícone aparece na barra de menus e o motor sobe sozinho. Clicar no ícone abre o painel: dublagem em andamento com progresso, recentes, voz (com botão para ouvir uma amostra), fonte da tradução, ajustes raros em "Mais ajustes", uso do cache e manutenção. Na primeira dublagem ele baixa os modelos (~400 MB).

A assinatura padrão é ad-hoc e muda a cada build, o que faz o macOS descartar permissões concedidas ao app (como o Acesso Total ao Disco). Para elas persistirem, assine com uma identidade estável: grave o nome dela em `macos/.sign-identity` (arquivo não versionado; veja as suas com `security find-identity -v -p codesigning`) ou passe `TDV_SIGN_IDENTITY="<nome>"` ao `build.sh`. Se a identidade mudar, o macOS pede as permissões de novo.

Para revisar o visual do painel sem abrir o app: `macos/.build/release/TradutorBar --snapshot <pasta>` gera PNGs dos estados de prévia nos temas claro e escuro.

Extensão: em `chrome://extensions`, ligue o **Modo do desenvolvedor**, clique em **Carregar sem compactação** e escolha a pasta `extension/`. O ID fica fixo (`ilmjfenckbenkgighlfojdejdoiiflmo`) por causa da chave no manifesto; o motor só aceita requisições de navegador vindas dessa origem.

## Usar

Abra um vídeo no YouTube e clique no balão que aparece nos controles do player. O botão mostra o progresso; quando fica azul, o áudio já é o dublado. Clique de novo para alternar entre dublado e original. Vídeos já dublados abrem na hora (cache).

No popup da extensão dá para ligar a dublagem automática, escolher a voz e a fonte da tradução.

## Como a tradução é escolhida

1. Legenda manual em português, se o vídeo tiver.
2. Faixa traduzida do próprio YouTube. Sem sessão o YouTube responde HTTP 429 nessa faixa, por isso a extensão envia ao motor os seus cookies do `youtube.com` (só esse domínio, só para `127.0.0.1`, gravados com permissão `0600` e nunca logados).
3. Plano B: tradução local com o Ollama, quando o YouTube nega a faixa.

Os cookies também podem vir direto do navegador pelo yt-dlp (`--cookies-from-browser`): ajuste `cookies_from_browser` (`"chrome"`, `"chrome:Profile 1"`, `"safari"`…) em `~/Library/Application Support/TradutorDeVideos/settings.json` ou via `PUT /settings`. Se o sistema negar o acesso à pasta do navegador, o motor avisa no log e usa os cookies enviados pela extensão. Isso funciona num shell comum, mas o app da barra de menus precisa de permissão: sem ela o macOS nega em silêncio a leitura da pasta do Chrome e o yt-dlp responde "could not find chrome cookies database". Dê **Acesso Total ao Disco** ao app em Ajustes do Sistema › Privacidade e Segurança e reabra o app. Como a assinatura é ad-hoc, um `./build.sh` novo pode exigir conceder de novo. No log, a linha `cookies lidos de chrome pelo yt-dlp: N` confirma que funcionou.

Com o Ollama ligado, o motor também pontua a transcrição automática (para cada fala virar uma frase completa) e enxuga as falas que não caberiam no tempo. Na barra de menus dá para trocar a tradução padrão para o Ollama: é mais lenta, mas costuma ficar melhor que a do YouTube.

## Volume e permissões

A voz dublada copia o volume da voz original fala a fala (medido na faixa de voz separada), o som de fundo fica como no vídeo, e o resultado segue a mesma regra de volume que o YouTube aplica ao original (nunca acima de −14 LUFS). Em "Mais ajustes" dá para deixar a voz 3 dB mais baixa ou mais alta. Dublagens feitas com a mixagem antiga são refeitas no próximo clique.

Ler os cookies do Chrome pelo yt-dlp exige **Acesso Total ao Disco**, e o macOS não deixa app nenhum pedir essa permissão por diálogo. O app detecta a falta dela, mostra um aviso com o botão que abre a lista certa em Ajustes do Sistema, percebe quando a chave é ligada e reinicia o motor sozinho. Quem não quiser conceder usa os cookies pela extensão, que não precisa de permissão. Com a assinatura estável (ver acima), a permissão sobrevive às atualizações.

## Linha de comando e testes

```bash
cd engine && uv run dub "https://www.youtube.com/watch?v=5C_HPTJg5ek"
```

```bash
cd engine && uv run pytest -q
```

Teste de ponta a ponta da extensão (precisa do motor no ar; usa um Chromium de teste, que só recebe o primeiro minuto de cada vídeo):

```bash
cd extension/e2e && npm install && npx playwright install chromium && npm test
```

## Onde ficam as coisas

| O quê | Onde |
|---|---|
| Cache por vídeo | `~/Library/Caches/TradutorDeVideos/<id>/` (`report.json` e `falas.json` mostram como cada fala foi encaixada) |
| Modelos, ajustes, cookies | `~/Library/Application Support/TradutorDeVideos/` |
| Logs | `~/Library/Logs/TradutorDeVideos/` |

## Quando quebrar

- **"YouTube recusou o vídeo" ou falha no download**: quase sempre é o yt-dlp desatualizado. Use **Atualizar yt-dlp** na barra de menus.
- **Botão sumiu do player**: o YouTube mudou o DOM. Rode o teste e2e para ver qual verificação falha.
- **Dublagem atropelada**: veja `falas_cortadas` e `velocidade_maxima` no `report.json`. Trocar a tradução para o Ollama ajuda, porque ele traduz já respeitando o tempo de cada fala.
