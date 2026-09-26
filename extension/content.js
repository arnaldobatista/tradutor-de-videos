// Content script do YouTube: botão no player, pedido de dublagem e áudio dublado em sincronia com o vídeo.
(() => {
  if (window.__tdvLoaded) return;
  window.__tdvLoaded = true;

  const CHUNK = 2 * 1024 * 1024;
  const POLL_MS = 1000;
  const DRIFT_SEEK_S = 0.3;   // acima disso, pula direto para o tempo do vídeo
  const DRIFT_NUDGE_S = 0.05; // abaixo do seek, corrige com micro-ajuste de velocidade

  const state = {
    videoId: null,
    status: "idle",     // idle | working | ready | error
    dubbed: false,
    job: null,
    audio: null,
    blobUrl: null,
    pollTimer: null,
    syncTimer: null,
    generation: 0,      // invalida trabalho assíncrono de um vídeo anterior
  };
  const route = { context: null, gain: null, fallback: false, userVolume: 1, guard: false };

  // ---------------------------------------------------------------- utilidades

  // O YouTube mantém um segundo player (#inline-preview-player) para o preview das miniaturas,
  // com a mesma classe: o vídeo que interessa é sempre o de dentro do #movie_player.
  const video = () => document.querySelector("#movie_player video.html5-main-video");
  const player = () => document.getElementById("movie_player");
  const adShowing = () => !!player()?.classList.contains("ad-showing");
  const watchId = () => (location.pathname === "/watch" ? new URLSearchParams(location.search).get("v") : null);

  function send(message) {
    return new Promise((resolve, reject) => {
      try {
        chrome.runtime.sendMessage(message, (reply) => {
          if (chrome.runtime.lastError) return reject(new Error("A extensão foi recarregada. Atualize a página."));
          if (!reply?.ok) return reject(new Error(reply?.error || "Falha na extensão."));
          resolve(reply.result);
        });
      } catch {
        reject(new Error("A extensão foi recarregada. Atualize a página."));
      }
    });
  }

  // ---------------------------------------------------------------- interface

  // Cor de destaque do app (a do macOS), aplicada no player para o botão e o aviso herdarem.
  let accent = null;

  function applyTheme() {
    const host = player();
    if (!host) return;
    if (accent) host.style.setProperty("--tdv-accent", accent);
    else host.style.removeProperty("--tdv-accent");
  }

  async function refreshTheme() {
    try {
      accent = (await send({ type: "engine:theme" })).accent;
    } catch {
      return; // motor fora do ar: fica a cor de antes
    }
    applyTheme();
  }

  function ensureButton() {
    const controls = document.querySelector(".ytp-right-controls");
    if (!controls) return null;
    let button = controls.querySelector(".tdv-button");
    if (!button) {
      button = document.createElement("button");
      button.className = "ytp-button tdv-button";
      // O ícone é uma máscara CSS num span (ver content.css): o YouTube aplica tamanho e padding
      // próprios a todo <svg> dentro de .ytp-button, o que cortava e deslocava um svg nosso.
      button.innerHTML = '<span class="tdv-icon" aria-hidden="true"></span><span class="tdv-label"></span>';
      button.addEventListener("click", onButtonClick);
      controls.prepend(button);
      applyTheme();
    }
    return button;
  }

  function render(message) {
    const button = ensureButton();
    if (!button) return;
    const label = button.querySelector(".tdv-label");
    button.dataset.status = state.status;
    button.dataset.dubbed = String(state.dubbed);
    label.textContent = state.status === "working" ? `${Math.round((state.job?.progress || 0) * 100)}%` : "";
    const titles = {
      idle: "Dublar em português",
      working: `${state.job?.stage_label || "Na fila"}… clique para cancelar`,
      ready: state.dubbed ? "Dublado — clique para ouvir o original" : "Original — clique para ouvir dublado",
      error: message || "Falhou — clique para tentar de novo",
    };
    button.title = titles[state.status];
    button.setAttribute("aria-label", titles[state.status]);
  }

  let toastTimer = null;
  function toast(text, sticky = false) {
    const host = player();
    if (!host) return;
    let box = host.querySelector(".tdv-toast");
    if (!box) {
      box = document.createElement("div");
      box.className = "tdv-toast";
      host.appendChild(box);
    }
    box.textContent = text;
    box.classList.add("tdv-visible");
    clearTimeout(toastTimer);
    if (!sticky) toastTimer = setTimeout(() => box.classList.remove("tdv-visible"), 4000);
  }

  // ---------------------------------------------------------------- áudio original

  // Caminho principal: o <video> passa por um GainNode, então o volume/mudo do YouTube continuam
  // funcionando e só espelhamos no áudio dublado. Se outra extensão já capturou o elemento,
  // caímos no plano B: volume do elemento travado em 0 enquanto o slider do YouTube segue livre.
  function muteOriginal(muted) {
    const element = video();
    if (!element) return;
    if (!route.context && !route.fallback) {
      try {
        route.context = new AudioContext();
        route.gain = route.context.createGain();
        route.context.createMediaElementSource(element).connect(route.gain).connect(route.context.destination);
      } catch {
        route.context?.close().catch(() => {});
        route.context = null;
        route.fallback = true;
      }
    }
    if (route.context) {
      route.context.resume().catch(() => {});
      route.gain.gain.value = muted ? 0 : 1;
    } else if (muted) {
      route.userVolume = element.volume || route.userVolume;
      route.guard = true;
      element.volume = 0;
    } else {
      route.guard = false;
      element.volume = route.userVolume;
    }
  }

  function currentVolume() {
    const element = video();
    if (!element) return { volume: 1, muted: false };
    return { volume: route.guard ? route.userVolume : element.volume, muted: element.muted };
  }

  // ---------------------------------------------------------------- sincronia

  function onVolumeChange() {
    const element = video();
    if (route.guard && element && element.volume > 0) {
      route.userVolume = element.volume;
      element.volume = 0;
    }
    if (state.audio) Object.assign(state.audio, currentVolume());
  }

  function alignAudio(force = false) {
    const element = video();
    const audio = state.audio;
    if (!element || !audio || !state.dubbed) return;
    if (adShowing()) {
      audio.pause();
      return;
    }
    const target = Math.min(element.currentTime, Math.max(0, (audio.duration || Infinity) - 0.05));
    const drift = audio.currentTime - target;
    if (force || Math.abs(drift) > DRIFT_SEEK_S) {
      audio.currentTime = target;
      audio.playbackRate = element.playbackRate;
    } else if (Math.abs(drift) > DRIFT_NUDGE_S) {
      audio.playbackRate = element.playbackRate * (drift > 0 ? 0.97 : 1.03);
    } else {
      audio.playbackRate = element.playbackRate;
    }
    const shouldPlay = !element.paused && !element.ended && element.readyState >= 3;
    if (shouldPlay && audio.paused) audio.play().catch(() => {});
    if (!shouldPlay && !audio.paused) audio.pause();
    // Diagnóstico visível no DOM (inspecionar o botão): usado pelo teste e2e e para depurar sincronia.
    const button = document.querySelector(".tdv-button");
    if (button) {
      Object.assign(button.dataset, {
        drift: drift.toFixed(3),
        audioTime: audio.currentTime.toFixed(2),
        audioPaused: String(audio.paused),
        route: route.context ? "webaudio" : "volume",
      });
    }
  }

  const videoEvents = {
    play: () => alignAudio(true),
    playing: () => alignAudio(true),
    pause: () => alignAudio(),
    waiting: () => state.audio?.pause(),
    seeking: () => state.audio?.pause(),
    seeked: () => alignAudio(true),
    ratechange: () => alignAudio(),
    ended: () => state.audio?.pause(),
    volumechange: onVolumeChange,
  };
  let boundVideo = null;
  function bindVideo() {
    const element = video();
    if (!element || element === boundVideo) return;
    for (const [name, handler] of Object.entries(videoEvents)) {
      boundVideo?.removeEventListener(name, handler);
      element.addEventListener(name, handler);
    }
    boundVideo = element;
  }

  function setDubbed(on) {
    state.dubbed = on && !!state.audio;
    const ad = adShowing();
    muteOriginal(state.dubbed && !ad);
    clearInterval(state.syncTimer);
    if (state.dubbed) {
      Object.assign(state.audio, currentVolume());
      alignAudio(true);
      state.syncTimer = setInterval(() => {
        muteOriginal(state.dubbed && !adShowing()); // anúncios tocam com o áudio deles
        alignAudio();
      }, 500);
    } else {
      state.audio?.pause();
    }
    render();
  }

  // ---------------------------------------------------------------- ciclo da dublagem

  async function loadAudio(job, generation) {
    const parts = [];
    let total = Infinity;
    for (let start = 0; start < total; start += CHUNK) {
      const chunk = await send({ type: "dub:audio-chunk", jobId: job.id, start, end: start + CHUNK - 1 });
      if (generation !== state.generation) return false;
      total = chunk.total;
      parts.push(Uint8Array.from(atob(chunk.data), (c) => c.charCodeAt(0)));
    }
    state.blobUrl = URL.createObjectURL(new Blob(parts, { type: "audio/mp4" }));
    state.audio = new Audio(state.blobUrl);
    state.audio.preload = "auto";
    state.audio.preservesPitch = true;
    return true;
  }

  async function startDub() {
    const videoId = watchId();
    if (!videoId) return;
    const generation = state.generation;
    state.status = "working";
    state.job = null;
    render();
    toast("Pedindo a dublagem ao motor…", true);
    try {
      let job = await send({ type: "dub:start", videoId });
      while (generation === state.generation) {
        state.job = job;
        render();
        if (job.status === "done") break;
        if (job.status === "error") throw new Error(job.error || "A dublagem falhou.");
        if (job.status === "cancelled") throw new Error("Dublagem cancelada.");
        toast(`${job.stage_label || "Na fila"}… ${Math.round(job.progress * 100)}%`, true);
        await new Promise((resolve) => { state.pollTimer = setTimeout(resolve, POLL_MS); });
        job = await send({ type: "dub:status", jobId: job.id });
      }
      if (generation !== state.generation) return;
      toast("Carregando o áudio dublado…", true);
      if (!(await loadAudio(job, generation))) return;
      state.status = "ready";
      bindVideo();
      setDubbed(true);
      toast(job.report?.aviso ? `Dublado. ${job.report.aviso}` : "Dublado em português.");
    } catch (error) {
      if (generation !== state.generation) return;
      state.status = "error";
      render(error.message);
      toast(error.message);
    }
  }

  function onButtonClick(event) {
    event.stopPropagation();
    if (state.status === "idle" || state.status === "error") startDub();
    else if (state.status === "ready") setDubbed(!state.dubbed);
    else if (state.status === "working" && state.job) {
      send({ type: "dub:cancel", jobId: state.job.id }).catch(() => {});
    }
  }

  function reset() {
    state.generation += 1;
    clearTimeout(state.pollTimer);
    clearInterval(state.syncTimer);
    state.audio?.pause();
    if (state.blobUrl) URL.revokeObjectURL(state.blobUrl);
    if (route.context || route.guard) muteOriginal(false);
    Object.assign(state, { status: "idle", dubbed: false, job: null, audio: null, blobUrl: null });
    document.querySelector(".tdv-toast")?.classList.remove("tdv-visible");
  }

  async function onNavigate() {
    const id = watchId();
    if (id === state.videoId) {
      ensureButton();
      return;
    }
    reset();
    state.videoId = id;
    if (!id) return;
    render();
    bindVideo();
    refreshTheme();
    const { autoDub = false } = await chrome.storage.sync.get("autoDub").catch(() => ({}));
    if (autoDub && watchId() === id && !player()?.classList.contains("ytp-live")) startDub();
  }

  document.addEventListener("yt-navigate-finish", onNavigate);
  // O YouTube reconstrói os controles de vez em quando; o botão volta sozinho.
  setInterval(() => { if (watchId()) { if (ensureButton()?.dataset.status !== state.status) render(); bindVideo(); } }, 2000);
  onNavigate();
})();
