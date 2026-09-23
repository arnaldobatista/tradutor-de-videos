// Popup: estado do motor e ajustes. Os ajustes do motor vivem no app; aqui é só um atalho.
const $ = (id) => document.getElementById(id);

function send(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(message, (reply) => {
      if (chrome.runtime.lastError || !reply?.ok) reject(new Error(reply?.error || "Falha na extensão."));
      else resolve(reply.result);
    });
  });
}

async function refresh() {
  try {
    const status = await send({ type: "engine:status" });
    $("dot").className = "dot on";
    $("engine").textContent = `Motor ativo (v${status.version})`;
    const job = status.jobs.current;
    $("job").hidden = !job;
    if (job) $("job").textContent = `${job.title || job.video_id}: ${job.stage_label} ${Math.round(job.progress * 100)}%`;
    $("voice").replaceChildren(...Object.entries(status.voices).map(([id, name]) => new Option(name, id)));
    $("voice").value = status.settings.voice;
    $("translator").value = status.settings.translator;
    $("cache").textContent = `Cache: ${(status.cache_bytes / 1e6).toFixed(0)} MB`;
    for (const id of ["voice", "translator", "clear"]) $(id).disabled = false;
  } catch (error) {
    $("dot").className = "dot off";
    $("engine").textContent = error.message;
    for (const id of ["voice", "translator", "clear"]) $(id).disabled = true;
  }
}

async function init() {
  const stored = await chrome.storage.sync.get({ autoDub: false, sendCookies: true });
  for (const key of ["autoDub", "sendCookies"]) {
    $(key).checked = stored[key];
    $(key).addEventListener("change", () => chrome.storage.sync.set({ [key]: $(key).checked }));
  }
  $("voice").addEventListener("change", () => send({ type: "engine:settings", changes: { voice: $("voice").value } }));
  $("translator").addEventListener("change", () =>
    send({ type: "engine:settings", changes: { translator: $("translator").value } }));
  $("clear").addEventListener("click", async () => {
    await send({ type: "engine:clear-cache" }).catch(() => {});
    refresh();
  });
  refresh();
  setInterval(refresh, 2000);
}

init();
