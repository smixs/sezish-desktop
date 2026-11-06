"use strict";

// Texts follow the Mac app (Localization.swift, SettingsStrings.swift); only the
// Windows-specific lines differ («компьютер» for «Мак», Ctrl, Explorer).
const strings = {
  ru: {
    general: "Общие",
    paneHistory: "История",
    quit: "Выйти из sezish",
    version: "Версия",
    checkUpdates: "Проверить обновления",
    shortcutLabel: "Клавиша диктовки",
    shortcutMode: "Режим клавиши",
    modeHold: "Удерживать",
    modeToggle: "Нажать",
    hotkeyModeHoldHint: "Запись идёт, пока клавиша удержана",
    hotkeyModeToggleHint: "Нажмите — начать, ещё раз — остановить. Esc — отмена",
    recorderPrompt: "Нажмите клавишу…",
    recorderNeedsModifier: "Добавьте Ctrl, Alt, Shift или Win",
    rightShiftWarning:
      "Правый Shift дольше 8 секунд включает системную «Фильтрацию ввода» и обрывает диктовку. Выберите другую клавишу.",
    keyLeft: "Левый",
    keyRight: "Правый",
    recognition: "Распознавание",
    waveIntensity: "Волна при диктовке",
    waveCalm: "Спокойно",
    waveLively: "Живее",
    waveBold: "Дерзко",
    hudPlacement: "Место плашки",
    hudBottom: "Внизу",
    hudTop: "Сверху",
    soundsToggle: "Звуки",
    soundVolume: "Громкость звуков",
    launchAtLogin: "Запуск при входе",
    advanced: "Дополнительно",
    language: "Язык",
    runAgain: "Пройти настройку заново",
    cloudTitle: "Облако",
    cloudSubtitle: "Быстро и без скачиваний. Нужен интернет",
    cloudUnavailable: "Облако недоступно в этой сборке",
    localTitle: "Локально",
    localSubtitle: "Офлайн, речь не покидает компьютер",
    geminiTitle: "Gemini",
    geminiSubtitle: "Через Google на вашем ключе. Нужен ключ Google AI Studio",
    geminiSection: "Gemini",
    geminiSmartTitle: "Умная расшифровка",
    geminiSmartSubtitle:
      "Убирает слова-паразиты и мат, расставляет пунктуацию. Выключите для дословного текста",
    geminiFooter: "Ключ хранится на этом компьютере и уходит только в Google",
    openaiTitle: "OpenAI",
    openaiSubtitle: "Запись уходит в OpenAI после отпускания клавиши. Нужен ключ OpenAI",
    openaiModelTranscribe: "GPT Transcribe",
    openaiModelTranscribeHint: "Точнее, около $0.005 за минуту",
    openaiModelMini: "GPT-4o mini Transcribe",
    openaiModelMiniHint: "Дешевле, около $0.003 за минуту. OpenAI отключит её 26 февраля 2027",
    openaiFooter: "Ключ хранится на этом компьютере и уходит только в OpenAI",
    keyLabel: "Ключ API",
    keyPlaceholder: "Вставьте ключ",
    keySaved: "Ключ сохранён",
    deleteKey: "Удалить ключ",
    getKey: "Получить ключ",
    keyMissing: "Без ключа диктовка идёт через облако или локальную модель",
    modelSection: "Модель",
    modelMultiTitle: "Русский, узбекский, казахский, кыргызский",
    modelMultiSubtitle: "Без знаков препинания. 215 МБ",
    modelRuEnTitle: "Русский и английский",
    modelRuEnSubtitle: "Знаки препинания и заглавные буквы. 225 МБ",
    modelFooter: "Модель работает на этом компьютере, без интернета",
    downloadModel: "Скачать модель",
    downloadingModel: "Скачивание модели…",
    modelInstalled: "Модель установлена",
    openFolder: "Открыть папку",
    search: "Поиск",
    nothingFound: "Ничего не найдено",
    emptyYet: "Пока пусто: продиктуйте что-нибудь, и текст появится здесь",
    noText: "Без текста — запись в папке",
    today: "Сегодня",
    yesterday: "Вчера",
    copy: "Скопировать",
    copied: "Скопировано",
    listen: "Послушать",
    retryTranscript: "Распознать заново",
    retrying: "Распознаю…",
    previewMode: "Предпросмотр: sezish не запущен",
    dismiss: "Закрыть",
    previewUpdateStatus: "В предпросмотре обновлений нет"
  },
  uz: {
    general: "Umumiy",
    paneHistory: "Tarix",
    quit: "sezishdan chiqish",
    version: "Versiya",
    checkUpdates: "Yangilanishlarni tekshirish",
    shortcutLabel: "Diktovka tugmasi",
    shortcutMode: "Tugma rejimi",
    modeHold: "Bosib turish",
    modeToggle: "Bosish",
    hotkeyModeHoldHint: "Yozish tugma bosib turilganda davom etadi",
    hotkeyModeToggleHint: "Bosing — boshlash, yana bosing — toʼxtatish. Esc — bekor qilish",
    recorderPrompt: "Tugmani bosing…",
    recorderNeedsModifier: "Ctrl, Alt, Shift yoki Win qoʼshing",
    rightShiftWarning:
      "Oʼng Shift 8 soniyadan uzoq bosib turilsa, tizim «Kirish filtri»ni yoqadi va diktovkani uzadi. Boshqa tugmani tanlang.",
    keyLeft: "Chap",
    keyRight: "Oʼng",
    recognition: "Nutqni aniqlash",
    waveIntensity: "Diktovkadagi toʼlqin",
    waveCalm: "Sokin",
    waveLively: "Jonli",
    waveBold: "Shiddatli",
    hudPlacement: "Plashka joyi",
    hudBottom: "Pastda",
    hudTop: "Tepada",
    soundsToggle: "Tovushlar",
    soundVolume: "Tovushlar balandligi",
    launchAtLogin: "Kirishda ishga tushirish",
    advanced: "Qoʼshimcha",
    language: "Til",
    runAgain: "Sozlashni qaytadan oʼtish",
    cloudTitle: "Bulut",
    cloudSubtitle: "Tez, yuklab olishsiz. Internet kerak",
    cloudUnavailable: "Bulut bu versiyada mavjud emas",
    localTitle: "Qurilmada",
    localSubtitle: "Oflayn, nutq kompyuterdan chiqmaydi",
    geminiTitle: "Gemini",
    geminiSubtitle: "Google orqali, oʼz kalitingiz bilan. Google AI Studio kaliti kerak",
    geminiSection: "Gemini",
    geminiSmartTitle: "Aqlli matn",
    geminiSmartSubtitle:
      "Ortiqcha soʼzlar va soʼkinishni olib tashlaydi, tinish belgilarini qoʼyadi. Soʼzma-soʼz matn uchun oʼchiring",
    geminiFooter: "Kalit shu kompyuterda saqlanadi va faqat Googlega yuboriladi",
    openaiTitle: "OpenAI",
    openaiSubtitle: "Tugma qoʼyib yuborilgach, yozuv OpenAIga yuboriladi. OpenAI kaliti kerak",
    openaiModelTranscribe: "GPT Transcribe",
    openaiModelTranscribeHint: "Aniqroq, daqiqasi taxminan $0.005",
    openaiModelMini: "GPT-4o mini Transcribe",
    openaiModelMiniHint: "Arzonroq, daqiqasi taxminan $0.003. OpenAI uni 2027-yil 26-fevralda oʼchiradi",
    openaiFooter: "Kalit shu kompyuterda saqlanadi va faqat OpenAIga yuboriladi",
    keyLabel: "API kaliti",
    keyPlaceholder: "Kalitni joylashtiring",
    keySaved: "Kalit saqlangan",
    deleteKey: "Kalitni oʼchirish",
    getKey: "Kalit olish",
    keyMissing: "Kalitsiz diktovka bulut yoki qurilmadagi model orqali ishlaydi",
    modelSection: "Model",
    modelMultiTitle: "Rus, oʼzbek, qozoq, qirgʼiz",
    modelMultiSubtitle: "Tinish belgilarisiz. 215 MB",
    modelRuEnTitle: "Rus va ingliz",
    modelRuEnSubtitle: "Tinish belgilari va bosh harflar bilan. 225 MB",
    modelFooter: "Model shu kompyuterda, internetsiz ishlaydi",
    downloadModel: "Modelni yuklab olish",
    downloadingModel: "Model yuklanmoqda…",
    modelInstalled: "Model oʼrnatilgan",
    openFolder: "Papkani ochish",
    search: "Qidiruv",
    nothingFound: "Hech narsa topilmadi",
    emptyYet: "Hozircha boʼsh: biror narsa ayting, matn shu yerda paydo boʼladi",
    noText: "Matnsiz — yozuv papkada",
    today: "Bugun",
    yesterday: "Kecha",
    copy: "Nusxalash",
    copied: "Nusxalandi",
    listen: "Tinglash",
    retryTranscript: "Qayta aniqlash",
    retrying: "Aniqlanmoqda…",
    previewMode: "Koʼrib chiqish: sezish ishga tushmagan",
    dismiss: "Yopish",
    previewUpdateStatus: "Koʼrib chiqishda yangilanish yoʼq"
  }
};

const now = Math.floor(Date.now() / 1000);
const fixture = {
  settings: {
    hotkey_mode: "hold",
    shortcut: { kind: "modifier", vk: 163 },
    transcription_mode: "local",
    effective_transcription_mode: "local",
    local_model: "multilingual",
    language: null,
    resolved_language: "ru",
    play_sounds: true,
    sound_volume: 50,
    openai_api_key_set: false,
    openai_model: "gpt-transcribe",
    gemini_api_key_set: false,
    gemini_smart_mode: true,
    hud_placement: "bottom",
    wave_intensity: "lively",
    cloud_available: true,
    autostart_enabled: false
  },
  history: [
    { text: "Завтра созвон в десять, подготовить короткий статус.", recorded_at: now - 600 },
    { text: "", recorded_at: now - 3_000 },
    { text: "Ertaga soat oʼnda qoʼngʼiroq bor.", recorded_at: now - 90_000 }
  ],
  modelStatus: { kind: "ready" },
  version: "0.1.10-preview"
};

const GEMINI_IN_RELEASE = false;

const tauriGlobal = window.__TAURI__;
const tauriInvoke =
  tauriGlobal && tauriGlobal.core && typeof tauriGlobal.core.invoke === "function"
    ? tauriGlobal.core.invoke.bind(tauriGlobal.core)
    : null;

const state = {
  pane: "general",
  advancedOpen: false,
  language: fixture.settings.resolved_language,
  settings: { ...fixture.settings },
  history: fixture.history.map((entry) => ({ ...entry })),
  query: "",
  copiedIndex: null,
  retryingIndex: null,
  modelStatus: { ...fixture.modelStatus },
  version: fixture.version,
  previewBannerVisible: !tauriInvoke,
  updateMessage: "",
  updateMessageIsPreview: false,
  errors: {},
  pollTimer: null,
  // Set when the recorder refused a right-Shift pick, so the warning explains a
  // shortcut that was not applied.
  rightShiftRejected: false
};

const elements = {};

function byId(id) {
  return document.getElementById(id);
}

function all(selector) {
  return Array.from(document.querySelectorAll(selector));
}

function cacheElements() {
  [
    "preview-banner",
    "dismiss-preview",
    "quit",
    "version-value",
    "check-updates",
    "updates-status",
    "shortcut-recorder",
    "shortcut-value",
    "shortcut-warning",
    "hotkey-hint",
    "open-recognition",
    "engine-name",
    "sound-volume",
    "sounds-toggle",
    "autostart-toggle",
    "advanced-toggle",
    "advanced-card",
    "back-to-general",
    "cloud-unavailable",
    "gemini-section",
    "gemini-key",
    "gemini-key-clear",
    "gemini-smart",
    "gemini-footer",
    "openai-section",
    "openai-key",
    "openai-key-clear",
    "openai-footer",
    "model-section",
    "model-status",
    "open-folder",
    "history-search",
    "history-list"
  ].forEach((id) => {
    elements[id] = byId(id);
  });
}

function currentStrings() {
  return strings[state.language] || strings.ru;
}

function errorMessage(error) {
  if (error && typeof error === "object" && typeof error.message === "string") {
    return error.message;
  }
  if (typeof error === "string") {
    try {
      const parsed = JSON.parse(error);
      if (parsed && typeof parsed.message === "string") {
        return parsed.message;
      }
    } catch {
      return error;
    }
    return error;
  }
  return String(error || "Unknown error");
}

// Several controls report into one line under their card.
const ERROR_SLOT = { hotkey: "controls", sounds: "controls", autostart: "controls", language: "controls" };

function setError(scope, error) {
  state.errors[ERROR_SLOT[scope] || scope] = error ? errorMessage(error) : "";
  renderErrors();
}

function renderErrors() {
  all("[data-error]").forEach((element) => {
    const message = state.errors[element.dataset.error] || "";
    element.textContent = message;
    element.hidden = !message;
  });
}

// ---------------------------------------------------------------- render --

function renderText() {
  const t = currentStrings();
  document.documentElement.lang = state.language;
  all("[data-t]").forEach((element) => {
    const text = t[element.dataset.t];
    if (text !== undefined) {
      element.textContent = text;
    }
  });
  all("[data-t-label]").forEach((element) => {
    const text = t[element.dataset.tLabel];
    if (text !== undefined) {
      element.setAttribute("aria-label", text);
    }
  });
  elements["history-search"].placeholder = t.search;
  if (state.updateMessageIsPreview) {
    state.updateMessage = t.previewUpdateStatus;
  }
  elements["updates-status"].textContent = state.updateMessage;
  elements["version-value"].textContent = state.version;
}

function check(elementsList, isOn) {
  elementsList.forEach((element) => {
    element.setAttribute("aria-checked", String(isOn(element)));
  });
}

function engineTitle(mode, t) {
  return {
    cloud: t.cloudTitle,
    local: t.localTitle,
    gemini: t.geminiTitle,
    openai: t.openaiTitle
  }[mode];
}

/// The CHOSEN mode, not the effective one (Mac `RecognitionPane.modeBinding`):
/// picking Gemini before pasting a key must keep the radio on Gemini, or the key
/// field it opens would close under the cursor. A build without the cloud reads
/// a cloud choice as local.
function chosenMode() {
  const settings = state.settings;
  return settings.transcription_mode === "cloud" && !settings.cloud_available
    ? "local"
    : settings.transcription_mode;
}

function renderPanes() {
  const pane = state.pane;
  byId("pane-general").hidden = pane !== "general";
  byId("pane-recognition").hidden = pane !== "recognition";
  byId("pane-history").hidden = pane !== "history";
  const navPane = pane === "recognition" ? "general" : pane;
  all(".nav-item").forEach((item) => {
    if (item.dataset.pane === navPane) {
      item.setAttribute("aria-current", "page");
    } else {
      item.removeAttribute("aria-current");
    }
  });
}

function renderGeneral() {
  const t = currentStrings();
  const settings = state.settings;
  if (!recorder.active) {
    elements["shortcut-value"].textContent = formatShortcut(settings.shortcut, t);
  }
  const rightShiftPicked = state.rightShiftRejected || isRightShift(settings.shortcut);
  elements["shortcut-warning"].textContent = rightShiftPicked ? t.rightShiftWarning : "";
  elements["shortcut-warning"].hidden = !rightShiftPicked;

  check(all("[data-hotkey-mode]"), (el) => el.dataset.hotkeyMode === settings.hotkey_mode);
  elements["hotkey-hint"].textContent =
    settings.hotkey_mode === "hold" ? t.hotkeyModeHoldHint : t.hotkeyModeToggleHint;
  elements["engine-name"].textContent = engineTitle(settings.effective_transcription_mode, t);
  check(all("[data-wave]"), (el) => el.dataset.wave === settings.wave_intensity);
  check(all("[data-placement]"), (el) => el.dataset.placement === settings.hud_placement);

  const volume = elements["sound-volume"];
  if (document.activeElement !== volume) {
    volume.value = String(settings.sound_volume);
  }
  volume.style.setProperty("--fill", `${volume.value}%`);
  volume.disabled = !settings.play_sounds;
  elements["sounds-toggle"].checked = settings.play_sounds;
  elements["autostart-toggle"].checked = settings.autostart_enabled;

  elements["advanced-toggle"].setAttribute("aria-expanded", String(state.advancedOpen));
  elements["advanced-card"].hidden = !state.advancedOpen;
  check(all("[data-language]"), (el) => el.dataset.language === state.language);
}

function renderKeyField(input, clear, isSet, t) {
  input.placeholder = isSet ? `${t.keySaved} ••••` : t.keyPlaceholder;
  clear.hidden = !isSet;
}

function renderRecognition() {
  const t = currentStrings();
  const settings = state.settings;
  const mode = chosenMode();
  const cloudRow = document.querySelector('[data-mode="cloud"]');
  // Without baked credentials the cloud is not offered at all; the footer
  // explains the absence instead of a dead radio button.
  cloudRow.hidden = !settings.cloud_available;
  elements["cloud-unavailable"].hidden = settings.cloud_available;
  // Release 1 ships without Gemini (Serge, 06.11.2026): it comes later as a
  // live stream like the Mac. The backend path stays for that release.
  document.querySelector('[data-mode="gemini"]').hidden = !GEMINI_IN_RELEASE;
  check(all("[data-mode]"), (el) => el.dataset.mode === mode);

  elements["gemini-section"].hidden = mode !== "gemini";
  renderKeyField(elements["gemini-key"], elements["gemini-key-clear"], settings.gemini_api_key_set, t);
  elements["gemini-smart"].checked = settings.gemini_smart_mode;
  renderFooter(elements["gemini-footer"], settings.gemini_api_key_set, t.geminiFooter, t);

  elements["openai-section"].hidden = mode !== "openai";
  renderKeyField(elements["openai-key"], elements["openai-key-clear"], settings.openai_api_key_set, t);
  check(all("[data-openai-model]"), (el) => el.dataset.openaiModel === settings.openai_model);
  renderFooter(elements["openai-footer"], settings.openai_api_key_set, t.openaiFooter, t);

  elements["model-section"].hidden = settings.effective_transcription_mode !== "local";
  check(all("[data-model]"), (el) =>
    el.dataset.model === (settings.local_model === "ru-en-punctuated" ? "ru-en-punctuated" : "multilingual")
  );
  renderModel();
}

/// No key means dictation silently runs somewhere else — said in red, the way a
/// failed model download is reported (Mac).
function renderFooter(element, keySet, footer, t) {
  element.textContent = keySet ? footer : t.keyMissing;
  element.classList.toggle("is-warning", !keySet);
}

function iconUse(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", `#i-${name}`);
  svg.append(use);
  return svg;
}

function renderModel() {
  const container = elements["model-status"];
  const status = state.modelStatus || { kind: "missing" };
  const t = currentStrings();
  container.replaceChildren();

  if (status.kind === "ready") {
    const ready = document.createElement("div");
    ready.className = "model-ready";
    const label = document.createElement("span");
    label.textContent = t.modelInstalled;
    ready.append(iconUse("check"), label);
    container.append(ready);
    return;
  }

  if (status.kind === "downloading") {
    const fraction = Math.min(1, Math.max(0, Number(status.fraction) || 0));
    const progress = document.createElement("div");
    progress.className = "model-progress";
    const line = document.createElement("div");
    line.className = "model-progress-line";
    const label = document.createElement("span");
    label.textContent = t.downloadingModel;
    const percent = document.createElement("span");
    percent.textContent = `${Math.floor(fraction * 100)} %`;
    line.append(label, percent);
    const track = document.createElement("div");
    track.className = "progress-track";
    track.setAttribute("role", "progressbar");
    track.setAttribute("aria-valuemin", "0");
    track.setAttribute("aria-valuemax", "100");
    track.setAttribute("aria-valuenow", String(Math.floor(fraction * 100)));
    const fill = document.createElement("div");
    fill.className = "progress-fill";
    fill.style.transform = `scaleX(${fraction})`;
    track.append(fill);
    progress.append(line, track);
    container.append(progress);
    return;
  }

  const button = document.createElement("button");
  button.type = "button";
  button.className = "primary-button";
  button.textContent = t.downloadModel;
  button.addEventListener("click", downloadModel);
  if (status.kind === "failed") {
    const message = document.createElement("div");
    message.className = "model-failure";
    message.textContent = status.message || "";
    container.append(message, button);
    return;
  }
  const spacer = document.createElement("div");
  spacer.className = "model-failure";
  container.append(spacer, button);
}

// ------------------------------------------------------------- history --

function dayKey(seconds) {
  const date = new Date(seconds * 1000);
  return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
}

function dayLabel(seconds, t) {
  const date = new Date(seconds * 1000);
  const today = new Date();
  const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  if (dayKey(seconds) === dayKey(today.getTime() / 1000)) return t.today;
  if (dayKey(seconds) === dayKey(yesterday.getTime() / 1000)) return t.yesterday;
  return new Intl.DateTimeFormat(state.language === "uz" ? "uz-UZ" : "ru-RU", {
    day: "numeric",
    month: "long"
  }).format(date);
}

function timeLabel(seconds) {
  return new Intl.DateTimeFormat("ru-RU", { hour: "2-digit", minute: "2-digit" }).format(
    new Date(seconds * 1000)
  );
}

function renderHistory() {
  const container = elements["history-list"];
  const t = currentStrings();
  container.replaceChildren();
  const query = state.query.trim().toLocaleLowerCase();
  const entries = state.history
    .map((entry, index) => ({ ...entry, index }))
    .filter((entry) => !query || (entry.text || "").toLocaleLowerCase().includes(query));

  if (entries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = query ? t.nothingFound : t.emptyYet;
    container.append(empty);
    return;
  }

  let card = null;
  let currentDay = null;
  entries.forEach((entry) => {
    const day = dayKey(entry.recorded_at);
    if (day !== currentDay) {
      currentDay = day;
      const header = document.createElement("h2");
      header.className = "day-header";
      header.textContent = dayLabel(entry.recorded_at, t);
      card = document.createElement("div");
      card.className = "card";
      container.append(header, card);
    }
    const row = document.createElement("div");
    row.className = "history-row";
    const time = document.createElement("span");
    time.className = "history-time";
    time.textContent = timeLabel(entry.recorded_at);
    const text = document.createElement("span");
    text.className = "history-text";
    text.textContent = entry.text || t.noText;
    text.classList.toggle("is-empty", !entry.text);
    row.append(time, text);
    const listen = document.createElement("button");
    listen.type = "button";
    listen.className = "history-copy";
    listen.setAttribute("aria-label", t.listen);
    listen.title = t.listen;
    listen.append(iconUse("speaker"));
    listen.addEventListener("click", () => simple("history", "play_history_entry", { index: entry.index }));
    row.append(listen);
    if (!entry.text) {
      const retry = document.createElement("button");
      retry.type = "button";
      retry.className = "control-button history-retry";
      retry.disabled = state.retryingIndex !== null;
      retry.textContent = state.retryingIndex === entry.index ? t.retrying : t.retryTranscript;
      retry.addEventListener("click", () => retryEntry(entry.index));
      row.append(retry);
    }
    if (entry.text) {
      const copy = document.createElement("button");
      copy.type = "button";
      const done = state.copiedIndex === entry.index;
      copy.className = `history-copy${done ? " is-done" : ""}`;
      copy.setAttribute("aria-label", done ? t.copied : t.copy);
      copy.title = done ? t.copied : t.copy;
      copy.append(iconUse(done ? "check" : "copy"));
      copy.addEventListener("click", () => copyDictation(entry.index));
      row.append(copy);
    }
    card.append(row);
  });
}

function renderAll() {
  elements["preview-banner"].hidden = !state.previewBannerVisible;
  renderText();
  renderPanes();
  renderGeneral();
  renderRecognition();
  renderHistory();
  renderErrors();
}

function applySettings(nextSettings) {
  if (!nextSettings || typeof nextSettings !== "object") {
    return;
  }
  state.settings = { ...state.settings, ...nextSettings };
  const resolved = nextSettings.resolved_language;
  if (resolved === "ru" || resolved === "uz") {
    state.language = resolved;
  }
}

// ------------------------------------------------------- preview backend --

function effectiveIn(settings) {
  const fallback = settings.cloud_available ? "cloud" : "local";
  switch (settings.transcription_mode) {
    case "local":
      return "local";
    case "gemini":
      return settings.gemini_api_key_set ? "gemini" : fallback;
    case "openai":
      return settings.openai_api_key_set ? "openai" : fallback;
    default:
      return fallback;
  }
}

async function fixtureInvoke(command, args = {}) {
  const settings = state.settings;
  const reply = () => {
    settings.effective_transcription_mode = effectiveIn(settings);
    return { ...settings };
  };
  switch (command) {
    case "get_settings":
      return reply();
    case "set_hotkey_mode":
      settings.hotkey_mode = args.mode;
      return reply();
    case "set_hotkey_key":
      settings.shortcut = args.shortcut;
      return reply();
    case "begin_hotkey_capture":
    case "end_hotkey_capture":
    case "copy_history_entry":
    case "open_history_folder":
    case "open_key_page":
    case "quit_app":
    case "open_onboarding":
    case "play_history_entry":
      return undefined;
    case "set_transcription_mode":
      settings.transcription_mode = args.mode;
      return reply();
    case "set_local_model":
      settings.local_model = args.model;
      state.modelStatus = args.model === "multilingual" ? { kind: "ready" } : { kind: "missing" };
      return reply();
    case "set_language":
      settings.language = args.language;
      settings.resolved_language = args.language;
      return reply();
    case "set_play_sounds":
      settings.play_sounds = args.enabled;
      return reply();
    case "set_sound_volume":
      settings.sound_volume = args.percent;
      return reply();
    case "set_hud_placement":
      settings.hud_placement = args.placement;
      return reply();
    case "set_wave_intensity":
      settings.wave_intensity = args.intensity;
      return reply();
    case "set_autostart":
      settings.autostart_enabled = args.enabled;
      return reply();
    case "set_gemini":
      if (args.key !== null && args.key !== undefined) settings.gemini_api_key_set = args.key.trim() !== "";
      if (args.smartMode !== null && args.smartMode !== undefined) settings.gemini_smart_mode = args.smartMode;
      return reply();
    case "set_openai":
      if (args.key !== null && args.key !== undefined) settings.openai_api_key_set = args.key.trim() !== "";
      if (args.model) settings.openai_model = args.model;
      return reply();
    case "retry_history_entry":
      state.history[args.index].text = "Восстановленный текст записи.";
      return state.history[args.index].text;
    case "history_entries":
      return state.history.map((entry) => ({ ...entry }));
    case "model_download_status":
      if (state.modelStatus.kind === "downloading") {
        const next = Math.min(1, state.modelStatus.fraction + 0.18);
        state.modelStatus = next >= 1 ? { kind: "ready" } : { kind: "downloading", fraction: next };
      }
      return { ...state.modelStatus };
    case "download_model":
      state.modelStatus = { kind: "downloading", fraction: 0 };
      return undefined;
    case "app_version":
      return state.version;
    case "check_for_updates":
      return { available: false, message: currentStrings().previewUpdateStatus };
    default:
      throw new Error(`Unsupported preview command: ${command}`);
  }
}

function invoke(command, args) {
  return tauriInvoke ? tauriInvoke(command, args) : fixtureInvoke(command, args);
}

/// Optimistic: the control moves at once, the backend's answer settles it, and a
/// refusal puts the old settings back with the reason under the card.
async function update(scope, change, command, args) {
  const previous = { ...state.settings };
  change(state.settings);
  setError(scope, null);
  renderAll();
  try {
    applySettings(await invoke(command, args));
  } catch (error) {
    state.settings = previous;
    setError(scope, error);
  }
  renderAll();
}

// --- Hotkey recorder --------------------------------------------------------

const recorder = {
  active: false,
  sawSecondModifier: false,
  committed: false,
  pendingModifier: null,
  altGr: false
};

const MODIFIER_CODES = {
  ControlLeft: 0xa2,
  ControlRight: 0xa3,
  AltLeft: 0xa4,
  AltRight: 0xa5,
  ShiftLeft: 0xa0,
  ShiftRight: 0xa1,
  MetaLeft: 0x5b,
  MetaRight: 0x5c
};

function codeToVk(code) {
  if (Object.prototype.hasOwnProperty.call(MODIFIER_CODES, code)) {
    return MODIFIER_CODES[code];
  }
  if (/^Key[A-Z]$/.test(code)) {
    return code.charCodeAt(3);
  }
  if (/^Digit[0-9]$/.test(code)) {
    return code.charCodeAt(5);
  }
  const fMatch = /^F([1-9]|1[0-2])$/.exec(code);
  if (fMatch) {
    return 0x70 + (Number(fMatch[1]) - 1);
  }
  if (code === "Space") {
    return 0x20;
  }
  return null;
}

function modsFromEvent(event) {
  const mods = [];
  if (event.ctrlKey) mods.push("ctrl");
  if (event.altKey) mods.push("alt");
  if (event.shiftKey) mods.push("shift");
  if (event.metaKey) mods.push("win");
  return mods;
}

function setRecorderText(text) {
  elements["shortcut-value"].textContent = text;
}

function toggleRecorder() {
  if (recorder.active) {
    cancelRecording();
  } else {
    startRecording();
  }
}

async function startRecording() {
  recorder.active = true;
  recorder.sawSecondModifier = false;
  recorder.committed = false;
  recorder.pendingModifier = null;
  recorder.altGr = false;
  setError("hotkey", null);
  elements["shortcut-recorder"].classList.add("is-recording");
  setRecorderText(currentStrings().recorderPrompt);
  document.addEventListener("keydown", onRecorderKeydown, true);
  document.addEventListener("keyup", onRecorderKeyup, true);
  window.addEventListener("blur", cancelRecording, { once: true });
  try {
    await invoke("begin_hotkey_capture");
  } catch (error) {
    setError("hotkey", error);
  }
}

async function stopRecording() {
  recorder.active = false;
  elements["shortcut-recorder"].classList.remove("is-recording");
  document.removeEventListener("keydown", onRecorderKeydown, true);
  document.removeEventListener("keyup", onRecorderKeyup, true);
  window.removeEventListener("blur", cancelRecording, { once: true });
  try {
    await invoke("end_hotkey_capture");
  } catch (error) {
    setError("hotkey", error);
  }
}

function cancelRecording() {
  if (!recorder.active) {
    return;
  }
  stopRecording();
  renderGeneral();
}

function onRecorderKeydown(event) {
  event.preventDefault();
  event.stopPropagation();
  const code = event.code;
  if (
    code === "Escape" &&
    !event.ctrlKey &&
    !event.altKey &&
    !event.shiftKey &&
    !event.metaKey
  ) {
    cancelRecording();
    return;
  }
  if (Object.prototype.hasOwnProperty.call(MODIFIER_CODES, code)) {
    // A second held modifier means this can't be a bare modifier-only shortcut.
    if (event.repeat) {
      return;
    }
    if (recorder.pendingModifier && recorder.pendingModifier !== code) {
      if (recorder.pendingModifier === "ControlLeft" && code === "AltRight") {
        // AltGr: Windows fakes a left Ctrl right before the right Alt. One
        // physical key, so keep recording it as a bare right Alt.
        recorder.altGr = true;
      } else {
        recorder.sawSecondModifier = true;
      }
    }
    recorder.pendingModifier = code;
    return;
  }
  const vk = codeToVk(code);
  if (vk === null) {
    return;
  }
  const mods = modsFromEvent(event);
  if (mods.length === 0 && !isFunctionVk(vk)) {
    setRecorderText(currentStrings().recorderNeedsModifier);
    return;
  }
  commitShortcut({ kind: "key", vk, mods });
}

function onRecorderKeyup(event) {
  if (!recorder.active) {
    return;
  }
  event.preventDefault();
  event.stopPropagation();
  const code = event.code;
  if (!Object.prototype.hasOwnProperty.call(MODIFIER_CODES, code)) {
    return;
  }
  if (recorder.altGr && !recorder.sawSecondModifier) {
    // The release comes as a pair too, and the faked Ctrl still reads as held on
    // the other event, so stillHeld would never clear: the first half of the
    // pair to come up ends the one physical key.
    if (!recorder.committed) {
      commitShortcut({ kind: "modifier", vk: MODIFIER_CODES.AltRight });
    }
    return;
  }
  const stillHeld = event.ctrlKey || event.altKey || event.shiftKey || event.metaKey;
  if (!recorder.committed && !recorder.sawSecondModifier && !stillHeld) {
    commitShortcut({ kind: "modifier", vk: MODIFIER_CODES[code] });
  }
}

function isRightShift(shortcut) {
  return (
    Boolean(shortcut) &&
    shortcut.kind === "modifier" &&
    shortcut.vk === MODIFIER_CODES.ShiftRight
  );
}

async function commitShortcut(shortcut) {
  recorder.committed = true;
  recorder.pendingModifier = null;
  await stopRecording();
  if (isRightShift(shortcut)) {
    // The warning says "choose another key", so the pick must not apply: the
    // previous shortcut stays and the recorder ends with the warning shown.
    state.rightShiftRejected = true;
    renderAll();
    return;
  }
  state.rightShiftRejected = false;
  state.settings.shortcut = shortcut;
  renderGeneral();
  try {
    applySettings(await invoke("set_hotkey_key", { shortcut }));
  } catch (error) {
    setError("hotkey", error);
  }
  renderAll();
}


// -------------------------------------------------------------- actions --

function setLanguage(language) {
  const previous = state.language;
  state.language = language;
  return update(
    "language",
    (settings) => {
      settings.language = language;
      settings.resolved_language = language;
    },
    "set_language",
    { language }
  ).then(() => {
    if (state.errors.controls) {
      state.language = previous;
      renderAll();
    }
  });
}

async function setTranscriptionMode(mode) {
  await update("recognition", (s) => (s.transcription_mode = mode), "set_transcription_mode", { mode });
  if (state.settings.effective_transcription_mode === "local") {
    await refreshModelStatus();
  }
}

async function setLocalModel(model) {
  await update("model", (s) => (s.local_model = model), "set_local_model", { model });
  await refreshModelStatus();
}

/// A pasted key goes to the backend on Enter or when the field is left; the field
/// then empties, and only «Ключ сохранён» says one is there.
function bindKeyField(provider) {
  const input = elements[`${provider}-key`];
  const clear = elements[`${provider}-key-clear`];
  const flag = `${provider}_api_key_set`;
  const save = async (key) => {
    await update("recognition", (s) => (s[flag] = key.trim() !== ""), `set_${provider}`, { key });
    input.value = "";
    renderAll();
  };
  input.addEventListener("change", () => {
    if (input.value.trim() !== "") {
      save(input.value);
    }
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      input.blur();
    }
  });
  clear.addEventListener("click", () => save(""));
}

async function copyDictation(index) {
  setError("history", null);
  try {
    await invoke("copy_history_entry", { index });
    state.copiedIndex = index;
    renderHistory();
    window.setTimeout(() => {
      if (state.copiedIndex === index) {
        state.copiedIndex = null;
        renderHistory();
      }
    }, 1500);
  } catch (error) {
    setError("history", error);
  }
}

/// The take through today's engine; the new text lands in the row and the clipboard.
async function retryEntry(index) {
  state.retryingIndex = index;
  setError("history", null);
  renderHistory();
  try {
    const text = await invoke("retry_history_entry", { index });
    if (state.history[index]) state.history[index].text = String(text || "");
    state.copiedIndex = index;
  } catch (error) {
    setError("history", error);
  }
  state.retryingIndex = null;
  renderHistory();
}

async function simple(scope, command, args) {
  setError(scope, null);
  try {
    await invoke(command, args);
  } catch (error) {
    setError(scope, error);
  }
}

async function refreshModelStatus() {
  try {
    state.modelStatus = await invoke("model_download_status");
    setError("model", null);
  } catch (error) {
    setError("model", error);
    return;
  }
  renderModel();
  if (state.modelStatus.kind === "downloading") {
    scheduleModelPoll();
  }
}

function scheduleModelPoll() {
  if (state.pollTimer !== null) {
    return;
  }
  state.pollTimer = window.setTimeout(async () => {
    state.pollTimer = null;
    await refreshModelStatus();
  }, 500);
}

async function downloadModel() {
  await simple("model", "download_model");
  await refreshModelStatus();
}

async function refreshHistory() {
  try {
    const history = await invoke("history_entries");
    state.history = Array.isArray(history) ? history : [];
    setError("history", null);
  } catch (error) {
    setError("history", error);
  }
  renderHistory();
}

async function checkForUpdates() {
  setError("updates", null);
  state.updateMessage = "";
  state.updateMessageIsPreview = false;
  renderText();
  try {
    const result = await invoke("check_for_updates");
    state.updateMessage = result && result.message ? result.message : "";
    state.updateMessageIsPreview = !tauriInvoke;
  } catch (error) {
    state.updateMessage = errorMessage(error);
  }
  renderText();
}

function showPane(pane) {
  state.pane = pane;
  renderPanes();
  byId("pane-" + pane).querySelector(".pane-title").focus({ preventScroll: true });
  elements["history-search"].value = state.query;
  if (pane === "history") {
    refreshHistory();
  }
}

function bindEvents() {
  elements["dismiss-preview"].addEventListener("click", () => {
    state.previewBannerVisible = false;
    renderAll();
  });
  all(".nav-item").forEach((item) => {
    item.addEventListener("click", () => showPane(item.dataset.pane));
  });
  elements["quit"].addEventListener("click", () => simple("general", "quit_app"));
  byId("run-onboarding").addEventListener("click", () => simple("controls", "open_onboarding"));
  elements["check-updates"].addEventListener("click", checkForUpdates);

  elements["shortcut-recorder"].addEventListener("click", toggleRecorder);
  all("[data-hotkey-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      const mode = button.dataset.hotkeyMode;
      update("hotkey", (s) => (s.hotkey_mode = mode), "set_hotkey_mode", { mode });
    });
  });
  elements["open-recognition"].addEventListener("click", () => showPane("recognition"));
  elements["back-to-general"].addEventListener("click", () => showPane("general"));
  all("[data-wave]").forEach((button) => {
    button.addEventListener("click", () => {
      const intensity = button.dataset.wave;
      update("controls", (s) => (s.wave_intensity = intensity), "set_wave_intensity", { intensity });
    });
  });
  all("[data-placement]").forEach((button) => {
    button.addEventListener("click", () => {
      const placement = button.dataset.placement;
      update("controls", (s) => (s.hud_placement = placement), "set_hud_placement", { placement });
    });
  });
  const volume = elements["sound-volume"];
  volume.addEventListener("input", () => volume.style.setProperty("--fill", `${volume.value}%`));
  // Heard on release, at the new level (Mac slider).
  volume.addEventListener("change", () => {
    const percent = Number(volume.value);
    update("sounds", (s) => (s.sound_volume = percent), "set_sound_volume", { percent });
  });
  elements["sounds-toggle"].addEventListener("change", (event) => {
    const enabled = event.target.checked;
    update("sounds", (s) => (s.play_sounds = enabled), "set_play_sounds", { enabled });
  });
  elements["autostart-toggle"].addEventListener("change", (event) => {
    const enabled = event.target.checked;
    update("autostart", (s) => (s.autostart_enabled = enabled), "set_autostart", { enabled });
  });
  elements["advanced-toggle"].addEventListener("click", () => {
    state.advancedOpen = !state.advancedOpen;
    renderGeneral();
  });
  all("[data-language]").forEach((button) => {
    button.addEventListener("click", () => setLanguage(button.dataset.language));
  });

  all("[data-mode]").forEach((button) => {
    button.addEventListener("click", () => setTranscriptionMode(button.dataset.mode));
  });
  bindKeyField("gemini");
  bindKeyField("openai");
  elements["gemini-smart"].addEventListener("change", (event) => {
    const smartMode = event.target.checked;
    update("recognition", (s) => (s.gemini_smart_mode = smartMode), "set_gemini", { key: null, smartMode });
  });
  all("[data-openai-model]").forEach((button) => {
    button.addEventListener("click", () => {
      const model = button.dataset.openaiModel;
      update("recognition", (s) => (s.openai_model = model), "set_openai", { key: null, model });
    });
  });
  all("[data-key-page]").forEach((button) => {
    button.addEventListener("click", () =>
      simple("recognition", "open_key_page", { provider: button.dataset.keyPage })
    );
  });
  all("[data-model]").forEach((button) => {
    button.addEventListener("click", () => setLocalModel(button.dataset.model));
  });

  elements["open-folder"].addEventListener("click", () => simple("history", "open_history_folder"));
  elements["history-search"].addEventListener("input", (event) => {
    state.query = event.target.value;
    renderHistory();
  });
  // The window stays alive in the tray; coming back to it shows fresh dictations.
  window.addEventListener("focus", () => {
    if (state.pane === "history") {
      refreshHistory();
    }
  });
}

async function loadInitialData() {
  const tasks = [
    invoke("get_settings").then(applySettings, (error) => setError("general", error)),
    invoke("model_download_status").then(
      (status) => (state.modelStatus = status),
      (error) => setError("model", error)
    ),
    invoke("history_entries").then(
      (history) => (state.history = Array.isArray(history) ? history : []),
      (error) => setError("history", error)
    ),
    invoke("app_version").then(
      (version) => (state.version = String(version)),
      () => {}
    )
  ];
  await Promise.all(tasks);
  renderAll();
  if (state.modelStatus.kind === "downloading") {
    scheduleModelPoll();
  }
}

function start() {
  if (tauriInvoke) {
    document.documentElement.dataset.shell = "tauri";
  }
  all(".pane-title").forEach((title) => title.setAttribute("tabindex", "-1"));
  cacheElements();
  bindEvents();
  renderAll();
  loadInitialData().catch((error) => setError("general", error));
}

start();
