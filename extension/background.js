// Service worker: único ponto da extensão que fala com o motor local.
// Requisições saem da origem da extensão (host_permissions), fora das restrições que o Chrome
// aplica a páginas públicas acessando 127.0.0.1.

const ENGINE = "http://127.0.0.1:47811";
const OFFLINE = "O motor não está respondendo. Abra o app Tradutor de Vídeos na barra de menus.";

async function engine(path, options = {}) {
  let response;
  try {
    response = await fetch(ENGINE + path, {
      ...options,
      headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    });
  } catch {
    throw new Error(OFFLINE);
  }
  if (!response.ok) {
    const detail = await response.json().then((body) => body.detail).catch(() => null);
    throw new Error(detail || `O motor respondeu ${response.status}.`);
  }
  return response;
}

// Os cookies do youtube.com vão para o yt-dlp do motor: sem sessão logada o YouTube
// responde 429 na faixa de legenda traduzida.
async function pushCookies() {
  const { sendCookies = true } = await chrome.storage.sync.get("sendCookies");
  if (!sendCookies) {
    await engine("/cookies", { method: "DELETE" });
    return;
  }
  const cookies = await chrome.cookies.getAll({ domain: "youtube.com" });
  const body = cookies.map((c) => ({
    domain: c.domain, name: c.name, value: c.value, path: c.path, secure: c.secure,
    httpOnly: c.httpOnly, hostOnly: c.hostOnly, expirationDate: c.expirationDate ?? null,
  }));
  await engine("/cookies", { method: "PUT", body: JSON.stringify({ cookies: body }) });
}

function toBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

const handlers = {
  async "dub:start"({ videoId }) {
    await pushCookies().catch((error) => console.warn("cookies não enviados:", error.message));
    return (await engine("/jobs", { method: "POST", body: JSON.stringify({ video_id: videoId }) })).json();
  },
  async "dub:status"({ jobId }) {
    return (await engine(`/jobs/${jobId}`)).json();
  },
  async "dub:cancel"({ jobId }) {
    return (await engine(`/jobs/${jobId}`, { method: "DELETE" })).json();
  },
  // O áudio vai para a página em blocos: a mensagem é independente, então sobrevive ao
  // service worker ser suspenso no meio da transferência.
  async "dub:audio-chunk"({ jobId, start, end }) {
    const response = await engine(`/jobs/${jobId}/audio`, { headers: { Range: `bytes=${start}-${end}` } });
    const range = response.headers.get("Content-Range");
    const total = range ? Number(range.split("/")[1]) : Number(response.headers.get("Content-Length"));
    return { total, data: toBase64(await response.arrayBuffer()) };
  },
  // Cor de destaque do macOS, publicada pelo app no motor: o botão e o popup usam a mesma cor do app.
  async "engine:theme"() {
    const settings = await (await engine("/settings")).json();
    const accent = settings.ui_accent || "";
    return { accent: /^#[0-9a-f]{6}$/i.test(accent) ? accent : null };
  },
  async "engine:status"() {
    return (await engine("/status")).json();
  },
  async "engine:settings"({ changes }) {
    return (await engine("/settings", { method: "PUT", body: JSON.stringify(changes) })).json();
  },
  async "engine:clear-cache"() {
    return (await engine("/cache/clear", { method: "POST" })).json();
  },
};

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  const handler = handlers[message?.type];
  if (!handler) return false;
  handler(message)
    .then((result) => sendResponse({ ok: true, result }))
    .catch((error) => sendResponse({ ok: false, error: error.message }));
  return true;
});
