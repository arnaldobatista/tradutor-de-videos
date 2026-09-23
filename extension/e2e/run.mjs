// Teste de ponta a ponta: carrega a extensão num Chromium de teste, abre um vídeo e confere
// botão, dublagem, sincronia (play, seek, velocidade, pausa), alternância e navegação.
// Pré-requisito: motor rodando em 127.0.0.1:47811.  Uso: npm test [-- <videoId>]
import { chromium } from "playwright";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EXTENSION = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const EXPECTED_ID = "ilmjfenckbenkgighlfojdejdoiiflmo";
const VIDEO = process.argv[2] || "5C_HPTJg5ek";
const SHOTS = process.env.TDV_SHOTS || tmpdir();
const results = [];

function check(name, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "PASSOU" : "FALHOU"}  ${name}${detail ? `  (${detail})` : ""}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const profile = mkdtempSync(join(tmpdir(), "tdv-e2e-"));
const context = await chromium.launchPersistentContext(profile, {
  channel: "chromium",
  headless: process.env.TDV_HEADED !== "1",
  viewport: { width: 1280, height: 800 },
  locale: "pt-BR",
  args: [
    `--disable-extensions-except=${EXTENSION}`,
    `--load-extension=${EXTENSION}`,
    "--autoplay-policy=no-user-gesture-required",
    "--mute-audio",
  ],
});

try {
  const worker = context.serviceWorkers()[0] ?? (await context.waitForEvent("serviceworker", { timeout: 15000 }));
  const id = new URL(worker.url()).host;
  check("service worker registrado com o ID fixo", id === EXPECTED_ID, id);

  const engine = await worker.evaluate(() =>
    fetch("http://127.0.0.1:47811/health").then((r) => r.json()).catch((e) => ({ error: String(e) })));
  check("service worker alcança o motor em 127.0.0.1", engine.ok === true, JSON.stringify(engine));

  const page = context.pages()[0] ?? (await context.newPage());
  page.on("console", (m) => { if (m.type() === "error" && /tdv|Tradutor/i.test(m.text())) console.log("  console:", m.text()); });
  await page.goto(`https://www.youtube.com/watch?v=${VIDEO}`, { waitUntil: "domcontentloaded" });

  // Tela de consentimento (fora do Brasil): escolhe a opção que recusa o que não é essencial.
  const reject = page.locator('button:has-text("Rejeitar tudo"), button:has-text("Reject all")').first();
  if (await reject.isVisible({ timeout: 4000 }).catch(() => false)) await reject.click();

  const button = page.locator(".tdv-button");
  await button.waitFor({ state: "attached", timeout: 30000 });
  check("botão injetado no player", true);

  const blocked = await page.locator("text=/confirm you.re not a bot|não é um robô/i").first()
    .isVisible({ timeout: 3000 }).catch(() => false);
  if (blocked) throw new Error("O YouTube pediu verificação anti-robô neste navegador de teste; nada a fazer aqui.");

  const video = page.locator("#movie_player video.html5-main-video");
  const data = async () => button.evaluate((b) => ({ ...b.dataset }));
  const vtime = async () => video.evaluate((v) => v.currentTime);
  // O drift é calculado dentro do content script (áudio e vídeo lidos no mesmo instante). Aqui só
  // garantimos que o vídeo está mesmo avançando e pegamos o pior valor de algumas amostras.
  const drift = async () => {
    await page.waitForFunction(() => {
      const v = document.querySelector("#movie_player video.html5-main-video");
      return v && !v.paused && !v.seeking && v.readyState >= 3;
    }, null, { timeout: 30000 });
    const before = await vtime();
    await sleep(1500);
    const advanced = (await vtime()) - before;
    if (advanced < 0.5) return { ok: false, text: `vídeo parado (avançou ${advanced.toFixed(2)} s)` };
    let worst = 0;
    for (let i = 0; i < 5; i += 1) {
      await sleep(600);
      const d = await data();
      if (d.audioPaused === "true") return { ok: false, text: "áudio dublado pausado com o vídeo tocando" };
      worst = Math.max(worst, Math.abs(Number(d.drift)));
    }
    return { ok: worst < 0.3, text: `pior drift ${worst.toFixed(3)} s` };
  };
  const checkSync = async (name) => { const r = await drift(); check(name, r.ok, r.text); };

  await video.evaluate((v) => { v.play().catch(() => {}); });
  await page.hover("#movie_player").catch(() => {});
  await button.evaluate((b) => b.click());
  await page.waitForFunction(() => document.querySelector(".tdv-button")?.dataset.status !== "idle", null, { timeout: 10000 });

  const started = Date.now();
  let last = "";
  while (Date.now() - started < 15 * 60 * 1000) {
    const d = await data();
    if (d.status === "ready" || d.status === "error") break;
    const label = await button.locator(".tdv-label").textContent();
    if (label !== last) { last = label; console.log(`  progresso: ${label} — ${await button.getAttribute("title")}`); }
    await sleep(2000);
  }
  let d = await data();
  check("dublagem pronta", d.status === "ready", `${d.status} — ${await button.getAttribute("title")}`);
  if (d.status !== "ready") throw new Error("sem dublagem, não há o que sincronizar");
  check("modo dublado ligado", d.dubbed === "true");

  // Anúncios tocam com o áudio original: espera passarem antes de medir sincronia.
  await page.waitForFunction(() => !document.getElementById("movie_player")?.classList.contains("ad-showing"),
    null, { timeout: 120000 }).catch(() => {});
  // Depois de uma dublagem demorada o vídeo já passou do primeiro minuto (o limite deste navegador
  // de teste): volta para o começo antes de medir.
  await page.evaluate(() => { const p = document.getElementById("movie_player"); p.seekTo(3, true); p.playVideo(); });
  await sleep(4000);
  d = await data();
  check("áudio original silenciado por WebAudio", d.route === "webaudio", d.route);
  check("áudio dublado tocando", d.audioPaused === "false", `audioTime=${d.audioTime}`);
  await checkSync("sincronia em reprodução normal (< 0,3 s)");

  // Seek e velocidade passam pela API do player, como a barra de progresso e o teclado fazem:
  // mexer em video.currentTime por fora não faz o YouTube baixar o trecho novo.
  // O Chromium automatizado só recebe o primeiro minuto do vídeo (o YouTube limita clientes que não
  // passam na atestação anti-robô), então o seek do teste fica dentro dessa janela.
  await page.evaluate(() => document.getElementById("movie_player").seekTo(25, true));
  await sleep(1500);
  await checkSync("sincronia depois de seek para 25 s");

  await page.evaluate(() => document.getElementById("movie_player").setPlaybackRate(2));
  await sleep(1500);
  await checkSync("sincronia em 2x");
  await page.evaluate(() => document.getElementById("movie_player").setPlaybackRate(1));

  await page.evaluate(() => document.getElementById("movie_player").pauseVideo());
  await sleep(1200);
  check("pausa o dublado junto com o vídeo", (await data()).audioPaused === "true");
  await page.screenshot({ path: join(SHOTS, "tdv-e2e-dublado.png") });

  await page.evaluate(() => document.getElementById("movie_player").playVideo());
  await sleep(1000);
  await button.evaluate((b) => b.click());
  await sleep(800);
  check("alterna para o original", (await data()).dubbed === "false");
  await button.evaluate((b) => b.click());
  await sleep(1500);
  check("volta para o modo dublado", (await data()).dubbed === "true");
  await checkSync("sincronia depois de alternar");

  // Navegação SPA: clica num vídeo recomendado e o estado tem que zerar.
  const next = page.locator('ytd-watch-next-secondary-results-renderer a[href^="/watch"]').first();
  if (await next.isVisible({ timeout: 8000 }).catch(() => false)) {
    await next.click();
    await page.waitForFunction((v) => !location.search.includes(v), VIDEO, { timeout: 20000 });
    await sleep(2500);
    d = await data();
    check("navegação SPA zera o estado", d.status === "idle" && d.dubbed === "false", `${d.status}/${d.dubbed}`);
  } else {
    console.log("PULADO  navegação SPA (sem recomendados visíveis)");
  }
} catch (error) {
  check("execução do teste", false, error.message);
} finally {
  await context.close();
  rmSync(profile, { recursive: true, force: true });
}

const failed = results.filter((ok) => !ok).length;
console.log(`\n${results.length - failed}/${results.length} verificações passaram`);
process.exit(failed ? 1 : 0);
