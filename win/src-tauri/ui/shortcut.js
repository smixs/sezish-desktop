"use strict";

// The shortcut as words («Правый Ctrl», «Ctrl + Alt + D»), shared by the settings
// window and the first-run tour.

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

function isFunctionVk(vk) {
  return vk >= 0x70 && vk <= 0x7b;
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
