"use strict";

// The first-run tour window. The flow itself lives in the backend
// (onboarding.rs, model specs/tla/WinOnboarding.tla); this page draws its state,
// sends the person's clicks and polls once a second while it is open.

const strings = {
  ru: {
    micTitle: "Пусть sezish вас слышит",
    micSubtitle: "Windows даёт доступ к микрофону в Параметрах, раздел «Конфиденциальность и защита».",
    microphone: "Микрофон",
    micHint: "Слушает, только пока вы держите клавишу",
    micDenied: "Выключен. Включите «Доступ к микрофону» и «Разрешить классическим приложениям»",
    micWaiting: "Включите оба переключателя в Параметрах и вернитесь сюда",
    allow: "Разрешить",
    allowed: "Разрешено",
    openSettings: "Открыть параметры",
    engineTitle: "Где распознавать речь",
    engineSubtitle: "Поменять можно в настройках, в разделе «Распознавание».",
    cloudTitle: "В облаке",
    cloudHint: "Работает сразу. Нужен интернет",
    localTitle: "На этом компьютере",
    localHint: "Без интернета, речь не покидает компьютер. Модель 215 МБ",
    recommended: "Рекомендуем",
    downloading: "Скачивается",
    downloadFailed: "Не скачалась",
    retry: "Повторить загрузку",
    ready: "Готово",
    doneTitle: "sezish готов",
    holdPrefix: "Удерживайте",
    holdSuffix: "где угодно и говорите",
    pressPrefix: "Нажмите",
    pressSuffix: "где угодно и говорите, нажмите ещё раз — готово",
    livesInTray: "Живёт в области уведомлений, у часов",
    start: "Начать",
    waitingForModel: "Ждём модель",
    continue: "Дальше",
    back: "Назад",
    keyLeft: "Левый",
    keyRight: "Правый"
  },
  uz: {
    micTitle: "sezish sizni eshitsin",
    micSubtitle: "Windows mikrofonga ruxsatni Sozlamalarning «Maxfiylik va xavfsizlik» boʼlimida beradi.",
    microphone: "Mikrofon",
    micHint: "Faqat tugmani bosib turganingizda eshitadi",
    micDenied: "Oʼchirilgan. «Mikrofonga ruxsat» va «Klassik ilovalarga ruxsat»ni yoqing",
    micWaiting: "Sozlamalarda ikkala tugmani yoqing va shu yerga qayting",
    allow: "Ruxsat berish",
    allowed: "Ruxsat berildi",
    openSettings: "Sozlamalarni ochish",
    engineTitle: "Nutq qayerda aniqlansin",
    engineSubtitle: "Sozlamalarning «Nutqni aniqlash» boʼlimida oʼzgartirish mumkin.",
    cloudTitle: "Bulutda",
    cloudHint: "Darhol ishlaydi. Internet kerak",
    localTitle: "Shu kompyuterda",
    localHint: "Internetsiz, nutq kompyuterdan chiqmaydi. Model 215 MB",
    recommended: "Tavsiya etamiz",
    downloading: "Yuklanmoqda",
    downloadFailed: "Yuklanmadi",
    retry: "Qaytadan yuklash",
    ready: "Tayyor",
    doneTitle: "sezish tayyor",
    holdPrefix: "Istalgan joyda",
    holdSuffix: "tugmasini bosib turib gapiring",
    pressPrefix: "Istalgan joyda",
    pressSuffix: "tugmasini bosib gapiring, yana bosing — tayyor",
    livesInTray: "Bildirishnomalar sohasida, soat yonida yashaydi",
    start: "Boshlash",
    waitingForModel: "Modelni kutyapmiz",
    continue: "Davom etish",
    back: "Orqaga",
    keyLeft: "Chap",
    keyRight: "Oʼng"
  }
};

const tauriGlobal = window.__TAURI__;
const tauriInvoke =
  tauriGlobal && tauriGlobal.core && typeof tauriGlobal.core.invoke === "function"
    ? tauriGlobal.core.invoke.bind(tauriGlobal.core)
    : null;

const state = {
  language: "ru",
  settings: { hotkey_mode: "hold", shortcut: { kind: "modifier", vk: 163 } },
  view: null,
  busy: false
};

// --- Browser preview: a small stand-in for the backend flow. -----------------
const preview = {
  step: "microphone",
  microphone: "denied",
  guide: false,
  engine: "cloud",
  model: { kind: "missing" }
};

function previewView(advance) {
  const row =
    preview.microphone === "granted" ? "ready" : preview.guide ? "waiting" : "denied";
  return {
    running: true,
    step: preview.step,
    microphone: row,
    engine: preview.engine,
    model: preview.model,
    engine_ready: preview.engine === "cloud" || preview.model.kind === "ready",
    cloud_baked: true,
    advance_soon: Boolean(advance)
  };
}

function previewAction(action) {
  const p = preview;
  if (action === "grant_microphone") {
    p.guide = true;
    window.setTimeout(() => (p.microphone = "granted"), 1500);
  } else if (action === "poll") {
    if (p.model.kind === "downloading") {
      const next = Math.min(1, p.model.fraction + 0.2);
      p.model = next >= 1 ? { kind: "ready" } : { kind: "downloading", fraction: next };
    }
    if (p.step === "microphone" && p.microphone === "granted" && !p.advanced) {
      p.advanced = true;
      return previewView(true);
    }
  } else if (action === "choose_local") {
    p.engine = "local";
    if (p.model.kind === "missing") p.model = { kind: "downloading", fraction: 0 };
  } else if (action === "choose_cloud") {
    p.engine = "cloud";
  } else if (action === "continue") {
    if (p.step === "microphone" && p.microphone === "granted") p.step = "engine";
    else if (p.step === "engine") p.step = "done";
    else if (p.step === "done" && previewView().engine_ready) p.step = "finished";
  } else if (action === "back") {
    p.step = p.step === "done" ? "engine" : "microphone";
  }
  return previewView(false);
}

function invoke(command, args = {}) {
  if (tauriInvoke) {
    return tauriInvoke(command, args);
  }
  if (command === "onboarding_action") return Promise.resolve(previewAction(args.action));
  if (command === "get_settings") {
    return Promise.resolve({ ...state.settings, resolved_language: state.language });
  }
  if (command === "set_language") {
    return Promise.resolve({ ...state.settings, resolved_language: args.language });
  }
  return Promise.resolve(undefined);
}

// --- Rendering -----------------------------------------------------------------

function t() {
  return strings[state.language] || strings.ru;
}

function byId(id) {
  return document.getElementById(id);
}

function renderText() {
  const s = t();
  document.documentElement.lang = state.language;
  document.querySelectorAll("[data-t]").forEach((element) => {
    const text = s[element.dataset.t];
    if (text !== undefined) element.textContent = text;
  });
  document.querySelectorAll("[data-language]").forEach((button) => {
    button.setAttribute("aria-checked", String(button.dataset.language === state.language));
  });
}

function percent(model) {
  return `${Math.round((Number(model.fraction) || 0) * 100)} %`;
}

function render() {
  const view = state.view;
  if (!view || !view.running) return;
  const s = t();
  renderText();

  const step = view.step === "finished" ? "done" : view.step;
  ["microphone", "engine", "done"].forEach((name) => {
    const screen = byId(`screen-${name}`);
    const show = name === step;
    if (screen.hidden === show) screen.hidden = !show;
  });
  byId("back").hidden = !(step === "engine" || step === "done");

  // Download progress follows the whole tour, above whatever screen is up.
  const downloading = view.model && view.model.kind === "downloading";
  byId("download-pill").hidden = !(downloading && step !== "engine");
  if (downloading) byId("download-percent").textContent = percent(view.model);

  // Microphone row.
  const row = view.microphone;
  byId("mic-hint").textContent =
    row === "denied" ? s.micDenied : row === "waiting" ? s.micWaiting : s.micHint;
  byId("mic-hint").classList.toggle("is-warning", row === "denied");
  byId("mic-allowed").hidden = row !== "ready";
  const grant = byId("mic-grant");
  grant.hidden = row === "ready";
  grant.textContent = row === "todo" ? s.allow : s.openSettings;

  // Engine choices.
  const cloud = byId("choose-cloud");
  cloud.hidden = !view.cloud_baked;
  cloud.setAttribute("aria-checked", String(view.engine === "cloud"));
  byId("choose-local").setAttribute("aria-checked", String(view.engine === "local"));
  const status = byId("local-status");
  const model = view.model || { kind: "missing" };
  status.className = "choice-status";
  status.textContent = "";
  if (view.engine === "local") {
    if (model.kind === "downloading") status.textContent = `${s.downloading} · ${percent(model)}`;
    if (model.kind === "ready") {
      status.textContent = s.ready;
      status.classList.add("is-ready");
    }
    if (model.kind === "failed") {
      status.textContent = s.downloadFailed;
      status.classList.add("is-failed");
    }
  }
  byId("retry").hidden = !(view.engine === "local" && model.kind === "failed");

  // Done.
  const hold = state.settings.hotkey_mode !== "toggle";
  const line = byId("key-line");
  line.replaceChildren();
  const cap = document.createElement("span");
  cap.className = "keycap";
  cap.textContent = formatShortcut(state.settings.shortcut, s);
  line.append(
    document.createTextNode(hold ? s.holdPrefix : s.pressPrefix),
    cap,
    document.createTextNode(hold ? s.holdSuffix : s.pressSuffix)
  );
  const start = byId("start");
  start.disabled = !view.engine_ready;
  start.textContent = view.engine_ready
    ? s.start
    : downloading
      ? `${s.waitingForModel} ${percent(model)}`
      : s.waitingForModel;
}

// --- Actions -------------------------------------------------------------------

async function act(action) {
  try {
    state.view = await invoke("onboarding_action", { action });
  } catch (error) {
    console.error(error);
    return;
  }
  render();
  if (state.view && state.view.advance_soon) {
    // The check is seen for a beat before the next screen (Mac).
    window.setTimeout(() => act("continue"), 700);
  }
  if (!tauriInvoke && state.view.step === "finished") {
    document.body.style.opacity = "0.4";
  }
}

async function setLanguage(language) {
  state.language = language;
  renderText();
  render();
  try {
    const settings = await invoke("set_language", { language });
    if (settings && settings.resolved_language) state.language = settings.resolved_language;
  } catch (error) {
    console.error(error);
  }
}

function bind() {
  byId("mic-grant").addEventListener("click", () => act("grant_microphone"));
  byId("choose-cloud").addEventListener("click", () => act("choose_cloud"));
  byId("choose-local").addEventListener("click", () => act("choose_local"));
  byId("retry").addEventListener("click", () => act("retry"));
  byId("engine-continue").addEventListener("click", () => act("continue"));
  byId("start").addEventListener("click", () => act("continue"));
  byId("back").addEventListener("click", () => act("back"));
  document.querySelectorAll("[data-language]").forEach((button) => {
    button.addEventListener("click", () => setLanguage(button.dataset.language));
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !byId("back").hidden) act("back");
  });
}

async function start() {
  if (tauriInvoke) document.documentElement.dataset.shell = "tauri";
  bind();
  try {
    const settings = await invoke("get_settings");
    if (settings) {
      state.settings = settings;
      if (settings.resolved_language) state.language = settings.resolved_language;
    }
  } catch (error) {
    console.error(error);
  }
  await act("poll");
  window.setInterval(() => act("poll"), 1000);
}

start();
