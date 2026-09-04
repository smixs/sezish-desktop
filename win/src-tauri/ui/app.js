"use strict";

const strings = {
  ru: {
    dictations: "Диктовки",
    openFolder: "Открыть папку",
    emptyYet: "Пока пусто",
    noTextRow: "🎙 без текста — открыть запись",
    checkUpdates: "Проверить обновления",
    downloadModel: "Скачать модель (215 МБ)",
    downloadingModel: "Скачивание модели…",
    modelInstalled: "Модель установлена",
    recognition: "Распознавание",
    cloudTitle: "Облако",
    cloudSubtitle: "Быстро и без скачиваний. Нужен интернет",
    cloudUnavailable: "Недоступно в этой сборке",
    localTitle: "Локально",
    localSubtitle: "Офлайн, речь не покидает компьютер. Модель 215 МБ",
    language: "Язык",
    general: "Общие",
    launchAtLogin: "Запуск при входе",
    soundsToggle: "Звуки",
    paneHotkey: "Горячая клавиша",
    hotkeySection: "Горячая клавиша диктовки",
    holdModeToggle: "Запись при удержании клавиши",
    hotkeyModeHoldHint: "Запись идёт, пока клавиша удержана",
    hotkeyModeToggleHint: "Нажмите — начать, ещё раз — остановить. Esc — отмена",
    shortcutLabel: "Сочетание клавиш",
    recorderPrompt: "Нажмите клавишу…  (Esc — отмена)",
    recorderNeedsModifier: "Добавьте Ctrl, Alt, Shift или Win",
    rightShiftWarning:
      "Правый Shift дольше 8 секунд включает системную «Фильтрацию ввода» и обрывает диктовку. Выберите другую клавишу.",
    keyLeft: "Левый",
    keyRight: "Правый",
    paneUpdates: "Обновления",
    updatesVersion: "Версия",
    settingsItem: "Настройки",
    previewMode: "Режим предпросмотра — sezish не запущен",
    dismiss: "Закрыть",
    previewUpdateStatus: "В режиме предпросмотра обновлений нет"
  },
  uz: {
    dictations: "Diktovkalar",
    openFolder: "Papkani ochish",
    emptyYet: "Hozircha boʼsh",
    noTextRow: "🎙 matn yoʼq — yozuvni ochish",
    checkUpdates: "Yangilanishlarni tekshirish",
    downloadModel: "Modelni yuklab olish (215 MB)",
    downloadingModel: "Model yuklanmoqda…",
    modelInstalled: "Model oʼrnatilgan",
    recognition: "Nutqni aniqlash",
    cloudTitle: "Bulut",
    cloudSubtitle: "Tez, yuklab olishsiz. Internet kerak",
    cloudUnavailable: "Bu versiyada mavjud emas",
    localTitle: "Qurilmada",
    localSubtitle: "Oflayn, nutq kompyuterdan chiqmaydi. Model 215 MB",
    language: "Til",
    general: "Umumiy",
    launchAtLogin: "Kirishda ishga tushirish",
    soundsToggle: "Tovushlar",
    paneHotkey: "Tezkor tugma",
    hotkeySection: "Diktovka uchun tezkor tugma",
    holdModeToggle: "Tugma bosib turilganda yozish",
    hotkeyModeHoldHint: "Yozish tugma bosib turilganda davom etadi",
    hotkeyModeToggleHint: "Bosing — boshlash, yana bosing — toʼxtatish. Esc — bekor qilish",
    shortcutLabel: "Tugmalar birikmasi",
    recorderPrompt: "Tugmani bosing…  (Esc - bekor)",
    recorderNeedsModifier: "Ctrl, Alt, Shift yoki Win qoʼshing",
    rightShiftWarning:
      "Oʼng Shift 8 soniyadan uzoq bosib turilsa, tizim «Kirish filtri»ni yoqadi va diktovkani uzadi. Boshqa tugmani tanlang.",
    keyLeft: "Chap",
    keyRight: "Oʼng",
    paneUpdates: "Yangilanishlar",
    updatesVersion: "Versiya",
    settingsItem: "Sozlamalar",
    previewMode: "Koʼrib chiqish rejimi — sezish ishga tushmagan",
    dismiss: "Yopish",
    previewUpdateStatus: "Koʼrib chiqish rejimida yangilanish yoʼq"
  }
};

const fixture = {
  settings: {
    hotkey_mode: "hold",
    shortcut: { kind: "modifier", vk: 163 },
    transcription_mode: "cloud",
    effective_transcription_mode: "local",
    language: null,
    resolved_language: "ru",
    play_sounds: true,
    autostart_enabled: false
  },
  history: [
    {
      text: "Завтра созвон в десять, подготовить короткий статус.",
      recorded_at: 1785169800
    },
    {
      text: "",
      recorded_at: 1785080700
    }
  ],
  modelStatus: {
    kind: "missing"
  },
  version: "0.0.1-preview",
  lastCopiedIndex: null,
  historyFolderOpened: false
};

const tauriGlobal = window.__TAURI__;
const tauriInvoke =
  tauriGlobal &&
  tauriGlobal.core &&
  typeof tauriGlobal.core.invoke === "function"
    ? tauriGlobal.core.invoke.bind(tauriGlobal.core)
    : null;

const state = {
  language: fixture.settings.resolved_language,
  settings: { ...fixture.settings },
  history: fixture.history.map((entry) => ({ ...entry })),
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

function cacheElements() {
  const ids = [
    "preview-banner",
    "preview-message",
    "dismiss-preview",
    "page-title",
    "general-heading",
    "general-error",
    "language-label",
    "language-uz",
    "language-ru",
    "language-error",
    "autostart-toggle",
    "autostart-label",
    "autostart-error",
    "sounds-toggle",
    "sounds-label",
    "sounds-error",
    "hotkey-heading",
    "hotkey-section-label",
    "hotkey-toggle",
    "hotkey-toggle-label",
    "hotkey-hint",
    "shortcut-label",
    "shortcut-recorder",
    "shortcut-value",
    "shortcut-warning",
    "hotkey-error",
    "recognition-heading",
    "mode-cloud",
    "mode-local",
    "cloud-title",
    "cloud-subtitle",
    "cloud-unavailable",
    "local-title",
    "local-subtitle",
    "recognition-error",
    "model-section",
    "model-status",
    "model-error",
    "history-heading",
    "open-folder",
    "history-list",
    "history-error",
    "updates-heading",
    "version-label",
    "version-value",
    "check-updates",
    "updates-status",
    "updates-error"
  ];
  ids.forEach((id) => {
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

function setError(scope, error) {
  state.errors[scope] = error ? errorMessage(error) : "";
  renderErrors();
}

function renderErrors() {
  const errorElements = {
    general: elements["general-error"],
    language: elements["language-error"],
    autostart: elements["autostart-error"],
    sounds: elements["sounds-error"],
    hotkey: elements["hotkey-error"],
    recognition: elements["recognition-error"],
    model: elements["model-error"],
    history: elements["history-error"],
    updates: elements["updates-error"]
  };
  Object.entries(errorElements).forEach(([scope, element]) => {
    const message = state.errors[scope] || "";
    element.textContent = message;
    element.hidden = !message;
  });
}

function renderText() {
  const t = currentStrings();
  document.documentElement.lang = state.language;
  elements["preview-message"].textContent = t.previewMode;
  elements["dismiss-preview"].setAttribute("aria-label", t.dismiss);
  elements["page-title"].textContent = t.settingsItem;
  elements["general-heading"].textContent = t.general;
  elements["language-label"].textContent = t.language;
  elements["autostart-label"].textContent = t.launchAtLogin;
  elements["sounds-label"].textContent = t.soundsToggle;
  elements["hotkey-heading"].textContent = t.paneHotkey;
  elements["hotkey-section-label"].textContent = t.hotkeySection;
  elements["hotkey-toggle-label"].textContent = t.holdModeToggle;
  elements["hotkey-hint"].textContent =
    state.settings.hotkey_mode === "hold"
      ? t.hotkeyModeHoldHint
      : t.hotkeyModeToggleHint;
  elements["shortcut-label"].textContent = t.shortcutLabel;
  elements["recognition-heading"].textContent = t.recognition;
  elements["cloud-title"].textContent = t.cloudTitle;
  elements["cloud-subtitle"].textContent = t.cloudSubtitle;
  elements["cloud-unavailable"].textContent = t.cloudUnavailable;
  elements["local-title"].textContent = t.localTitle;
  elements["local-subtitle"].textContent = t.localSubtitle;
  elements["history-heading"].textContent = t.dictations;
  elements["open-folder"].textContent = t.openFolder;
  elements["updates-heading"].textContent = t.paneUpdates;
  elements["version-label"].textContent = t.updatesVersion;
  elements["check-updates"].textContent = t.checkUpdates;
  if (state.updateMessageIsPreview) {
    state.updateMessage = t.previewUpdateStatus;
  }
  elements["updates-status"].textContent = state.updateMessage;
}

function renderControls() {
  const settings = state.settings;
  elements["language-uz"].setAttribute(
    "aria-checked",
    String(state.language === "uz")
  );
  elements["language-ru"].setAttribute(
    "aria-checked",
    String(state.language === "ru")
  );
  elements["autostart-toggle"].checked = settings.autostart_enabled;
  elements["sounds-toggle"].checked = settings.play_sounds;
  elements["hotkey-toggle"].checked = settings.hotkey_mode === "hold";
  if (!recorder.active) {
    elements["shortcut-value"].textContent = formatShortcut(
      settings.shortcut,
      currentStrings()
    );
  }
  const rightShiftPicked =
    state.rightShiftRejected ||
    (Boolean(settings.shortcut) &&
      settings.shortcut.kind === "modifier" &&
      settings.shortcut.vk === MODIFIER_CODES.ShiftRight);
  elements["shortcut-warning"].textContent = rightShiftPicked
    ? currentStrings().rightShiftWarning
    : "";
  elements["shortcut-warning"].hidden = !rightShiftPicked;
  elements["mode-cloud"].setAttribute(
    "aria-checked",
    String(settings.transcription_mode === "cloud")
  );
  elements["mode-local"].setAttribute(
    "aria-checked",
    String(settings.transcription_mode === "local")
  );
  elements["cloud-unavailable"].hidden = !(
    settings.transcription_mode !== settings.effective_transcription_mode &&
    settings.transcription_mode === "cloud"
  );
  elements["model-section"].hidden =
    settings.effective_transcription_mode !== "local";
}

function createModelButton() {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "primary-button";
  button.textContent = currentStrings().downloadModel;
  button.addEventListener("click", downloadModel);
  return button;
}

function renderModel() {
  const container = elements["model-status"];
  const status = state.modelStatus || { kind: "missing" };
  const t = currentStrings();
  container.replaceChildren();

  if (status.kind === "ready") {
    const ready = document.createElement("div");
    ready.className = "model-ready";
    const dot = document.createElement("span");
    dot.className = "ready-dot";
    dot.setAttribute("aria-hidden", "true");
    const label = document.createElement("span");
    label.textContent = t.modelInstalled;
    ready.append(dot, label);
    container.append(ready);
    return;
  }

  if (status.kind === "downloading") {
    const fraction = Math.min(1, Math.max(0, Number(status.fraction) || 0));
    const row = document.createElement("div");
    row.className = "model-status-row";
    const label = document.createElement("span");
    label.textContent = t.downloadingModel;
    const percent = document.createElement("span");
    percent.className = "version-value";
    percent.textContent = `${Math.floor(fraction * 100)} %`;
    row.append(label, percent);

    const track = document.createElement("div");
    track.className = "progress-track";
    track.setAttribute("role", "progressbar");
    track.setAttribute("aria-valuemin", "0");
    track.setAttribute("aria-valuemax", "100");
    track.setAttribute("aria-valuenow", String(Math.floor(fraction * 100)));
    const fill = document.createElement("div");
    fill.className = "progress-fill";
    fill.style.width = `${fraction * 100}%`;
    track.append(fill);
    container.append(row, track);
    return;
  }

  if (status.kind === "failed") {
    const message = document.createElement("div");
    message.className = "model-failure";
    message.textContent = status.message || "";
    container.append(message, createModelButton());
    return;
  }

  container.append(createModelButton());
}

function formatTimestamp(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value)) {
    return "";
  }
  return new Intl.DateTimeFormat(state.language === "uz" ? "uz-UZ" : "ru-RU", {
    dateStyle: "short",
    timeStyle: "short"
  }).format(new Date(value * 1000));
}

function renderHistory() {
  const container = elements["history-list"];
  const t = currentStrings();
  container.replaceChildren();
  if (state.history.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = t.emptyYet;
    container.append(empty);
    return;
  }

  state.history.forEach((entry, index) => {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "history-row";
    if (!entry.text) {
      row.classList.add("is-empty");
    }
    const text = document.createElement("span");
    text.className = "history-text";
    text.textContent = entry.text || t.noTextRow;
    const time = document.createElement("span");
    time.className = "history-time";
    time.textContent = formatTimestamp(entry.recorded_at);
    row.append(text, time);
    row.addEventListener("click", () => copyDictation(index));
    container.append(row);
  });
}

function renderAll() {
  elements["preview-banner"].hidden = !state.previewBannerVisible;
  renderText();
  renderControls();
  renderModel();
  renderHistory();
  elements["version-value"].textContent = state.version;
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

async function fixtureInvoke(command, args = {}) {
  if (command === "get_settings") {
    return { ...state.settings };
  }
  if (command === "set_hotkey_mode") {
    state.settings.hotkey_mode = args.mode;
    return { ...state.settings };
  }
  if (command === "set_hotkey_key") {
    state.settings.shortcut = args.shortcut;
    return { ...state.settings };
  }
  if (command === "begin_hotkey_capture" || command === "end_hotkey_capture") {
    return undefined;
  }
  if (command === "set_transcription_mode") {
    state.settings.transcription_mode = args.mode;
    state.settings.effective_transcription_mode =
      args.mode === "cloud" ? "local" : args.mode;
    return { ...state.settings };
  }
  if (command === "set_language") {
    state.settings.language = args.language;
    state.settings.resolved_language = args.language;
    return { ...state.settings };
  }
  if (command === "set_play_sounds") {
    state.settings.play_sounds = args.enabled;
    return { ...state.settings };
  }
  if (command === "set_autostart") {
    state.settings.autostart_enabled = args.enabled;
    return { ...state.settings };
  }
  if (command === "recent_dictations") {
    return state.history.map((entry) => ({ ...entry }));
  }
  if (command === "copy_dictation") {
    fixture.lastCopiedIndex = args.index;
    return undefined;
  }
  if (command === "model_download_status") {
    if (state.modelStatus.kind === "downloading") {
      const nextFraction = Math.min(1, state.modelStatus.fraction + 0.18);
      state.modelStatus =
        nextFraction >= 1
          ? { kind: "ready" }
          : { kind: "downloading", fraction: nextFraction };
    }
    return { ...state.modelStatus };
  }
  if (command === "download_model") {
    state.modelStatus = { kind: "downloading", fraction: 0 };
    return undefined;
  }
  if (command === "open_history_folder") {
    fixture.historyFolderOpened = true;
    return undefined;
  }
  if (command === "app_version") {
    return state.version;
  }
  if (command === "check_for_updates") {
    return {
      available: false,
      message: currentStrings().previewUpdateStatus
    };
  }
  throw new Error(`Unsupported preview command: ${command}`);
}

function invoke(command, args) {
  return tauriInvoke ? tauriInvoke(command, args) : fixtureInvoke(command, args);
}

async function setHotkeyMode() {
  const previous = state.settings.hotkey_mode;
  const mode = elements["hotkey-toggle"].checked ? "hold" : "toggle";
  state.settings.hotkey_mode = mode;
  setError("hotkey", null);
  renderAll();
  try {
    applySettings(await invoke("set_hotkey_mode", { mode }));
  } catch (error) {
    state.settings.hotkey_mode = previous;
    setError("hotkey", error);
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

const MODIFIER_VK = {
  0xa0: ["left", "Shift"],
  0xa1: ["right", "Shift"],
  0xa2: ["left", "Ctrl"],
  0xa3: ["right", "Ctrl"],
  0xa4: ["left", "Alt"],
  0xa5: ["right", "Alt"],
  0x5b: ["left", "Win"],
  0x5c: ["right", "Win"]
};

const MOD_NAME = { ctrl: "Ctrl", alt: "Alt", shift: "Shift", win: "Win" };
const MOD_ORDER = ["ctrl", "alt", "shift", "win"];

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

function isFunctionVk(vk) {
  return vk >= 0x70 && vk <= 0x7b;
}

function modsFromEvent(event) {
  const mods = [];
  if (event.ctrlKey) mods.push("ctrl");
  if (event.altKey) mods.push("alt");
  if (event.shiftKey) mods.push("shift");
  if (event.metaKey) mods.push("win");
  return mods;
}

function mainKeyName(vk) {
  if ((vk >= 0x30 && vk <= 0x39) || (vk >= 0x41 && vk <= 0x5a)) {
    return String.fromCharCode(vk);
  }
  if (isFunctionVk(vk)) {
    return `F${vk - 0x6f}`;
  }
  if (vk === 0x20) {
    return "Space";
  }
  return `0x${vk.toString(16).toUpperCase()}`;
}

function formatShortcut(shortcut, t) {
  if (!shortcut || typeof shortcut !== "object") {
    return "";
  }
  if (shortcut.kind === "modifier") {
    const info = MODIFIER_VK[shortcut.vk];
    if (!info) {
      return mainKeyName(shortcut.vk);
    }
    const side = info[0] === "right" ? t.keyRight : t.keyLeft;
    return `${side} ${info[1]}`;
  }
  if (shortcut.kind === "key") {
    const mods = (shortcut.mods || [])
      .slice()
      .sort((a, b) => MOD_ORDER.indexOf(a) - MOD_ORDER.indexOf(b))
      .map((mod) => MOD_NAME[mod] || mod);
    return mods.concat([mainKeyName(shortcut.vk)]).join(" + ");
  }
  return "";
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
  renderControls();
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
  renderControls();
  try {
    applySettings(await invoke("set_hotkey_key", { shortcut }));
  } catch (error) {
    setError("hotkey", error);
  }
  renderAll();
}

async function setTranscriptionMode(mode) {
  const previous = { ...state.settings };
  state.settings.transcription_mode = mode;
  setError("recognition", null);
  renderAll();
  try {
    applySettings(await invoke("set_transcription_mode", { mode }));
    if (state.settings.effective_transcription_mode === "local") {
      await refreshModelStatus();
    }
  } catch (error) {
    state.settings = previous;
    setError("recognition", error);
  }
  renderAll();
}

async function setLanguage(language) {
  const previousLanguage = state.language;
  const previousSettings = { ...state.settings };
  state.language = language;
  state.settings.language = language;
  state.settings.resolved_language = language;
  setError("language", null);
  renderAll();
  try {
    applySettings(await invoke("set_language", { language }));
  } catch (error) {
    state.language = previousLanguage;
    state.settings = previousSettings;
    setError("language", error);
  }
  renderAll();
}

async function setSounds() {
  const previous = state.settings.play_sounds;
  const enabled = elements["sounds-toggle"].checked;
  state.settings.play_sounds = enabled;
  setError("sounds", null);
  try {
    applySettings(await invoke("set_play_sounds", { enabled }));
  } catch (error) {
    state.settings.play_sounds = previous;
    setError("sounds", error);
  }
  renderAll();
}

async function setAutostart() {
  const previous = state.settings.autostart_enabled;
  const enabled = elements["autostart-toggle"].checked;
  state.settings.autostart_enabled = enabled;
  setError("autostart", null);
  try {
    applySettings(await invoke("set_autostart", { enabled }));
  } catch (error) {
    state.settings.autostart_enabled = previous;
    setError("autostart", error);
  }
  renderAll();
}

async function copyDictation(index) {
  setError("history", null);
  try {
    await invoke("copy_dictation", { index });
  } catch (error) {
    setError("history", error);
  }
}

async function openHistoryFolder() {
  setError("history", null);
  try {
    await invoke("open_history_folder");
  } catch (error) {
    setError("history", error);
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
  setError("model", null);
  try {
    await invoke("download_model");
    await refreshModelStatus();
  } catch (error) {
    setError("model", error);
  }
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
    setError("updates", error);
  }
  renderText();
}

function bindEvents() {
  elements["dismiss-preview"].addEventListener("click", () => {
    state.previewBannerVisible = false;
    renderAll();
  });
  elements["language-uz"].addEventListener("click", () => setLanguage("uz"));
  elements["language-ru"].addEventListener("click", () => setLanguage("ru"));
  elements["autostart-toggle"].addEventListener("change", setAutostart);
  elements["sounds-toggle"].addEventListener("change", setSounds);
  elements["hotkey-toggle"].addEventListener("change", setHotkeyMode);
  elements["shortcut-recorder"].addEventListener("click", toggleRecorder);
  elements["mode-cloud"].addEventListener("click", () =>
    setTranscriptionMode("cloud")
  );
  elements["mode-local"].addEventListener("click", () =>
    setTranscriptionMode("local")
  );
  elements["open-folder"].addEventListener("click", openHistoryFolder);
  elements["check-updates"].addEventListener("click", checkForUpdates);
}

async function loadInitialData() {
  const tasks = [
    invoke("get_settings")
      .then((settings) => {
        applySettings(settings);
      })
      .catch((error) => {
        setError("general", error);
      }),
    invoke("model_download_status")
      .then((status) => {
        state.modelStatus = status;
      })
      .catch((error) => {
        setError("model", error);
      }),
    invoke("recent_dictations")
      .then((history) => {
        state.history = Array.isArray(history) ? history : [];
      })
      .catch((error) => {
        setError("history", error);
      }),
    invoke("app_version")
      .then((version) => {
        state.version = String(version);
      })
      .catch((error) => {
        setError("updates", error);
      })
  ];
  await Promise.all(tasks);
  renderAll();
  if (state.modelStatus.kind === "downloading") {
    scheduleModelPoll();
  }
}

function start() {
  cacheElements();
  bindEvents();
  renderAll();
  loadInitialData().catch((error) => {
    setError("general", error);
  });
}

start();
