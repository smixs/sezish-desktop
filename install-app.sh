#!/bin/bash
# sezish.app installer - dictation & meeting transcription for macOS.
# Usage: curl -fsSL sezi.sh/app | bash
#
# Downloads via curl on purpose: curl never sets the com.apple.quarantine
# attribute, so Gatekeeper has nothing to block even offline. The bundle carries
# our notarized Developer ID signature, whose stable identity preserves TCC
# grants (mic, Accessibility) across updates.
set -euo pipefail

# Served from our own box (dl.sezi.sh, h1): the GitHub repo is private, so
# release-asset URLs are dead for anonymous users.
ZIP_URL="https://dl.sezi.sh/sezish-app.zip"

say() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "sezish supports macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "sezish needs Apple Silicon (M1 or newer)."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Скачиваю sezish… / sezish yuklab olinmoqda…"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/sezish-app.zip"
ditto -x -k "$TMP/sezish-app.zip" "$TMP/unpacked"
[[ -d "$TMP/unpacked/sezish.app" ]] || die "bad archive"

say "Устанавливаю в Программы… / Программы papkasiga oʼrnatilmoqda…"
killall sezish 2>/dev/null || true
rm -rf /Applications/sezish.app
ditto "$TMP/unpacked/sezish.app" /Applications/sezish.app
# no-op on the curl path; belt-and-braces if the zip was ever browser-downloaded
xattr -dr com.apple.quarantine /Applications/sezish.app 2>/dev/null || true

say "Запускаю sezish… / sezish ishga tushmoqda…"
open /Applications/sezish.app

cat <<'DONE'

  Готово! Дальше в самом приложении:
   • скачайте модель распознавания (~215 МБ, один раз);
   • выдайте доступ к микрофону и «Универсальному доступу»;
   • зажмите горячую клавишу, скажите, отпустите - текст на месте.

  Tayyor! Endi dasturning oʼzida:
   • modelni yuklab oling (~215 MB, bir marta);
   • mikrofon va «Универсальный доступ» ruxsatlarini bering;
   • tezkor tugmani bosib turing, gapiring, qoʼyib yuboring.

DONE
