#!/bin/sh
# Конфиги моделей (Onboarding, MeetingTitle) под TLC с ожиданием по каждому: none или имя нарушенного свойства.
# Любой сбой tlc или несовпадение ожидания — ненулевой выход.
set -u
cd "$(dirname "$0")" || exit 2
. ./tlc-result.sh || exit 2
# The system java stub may be absent; Homebrew's JDK works.
[ -x /opt/homebrew/opt/openjdk@25/bin/java ] && PATH=/opt/homebrew/opt/openjdk@25/bin:$PATH
TLC=${TLC:-$(command -v tlc || echo "$HOME/.local/bin/tlc")}
[ -x "$TLC" ] || { echo "check: tlc not found (set TLC=/path/to/tlc)"; exit 2; }
WORKERS=${WORKERS:-4}
META=$(mktemp -d) || exit 2
trap 'rm -rf "$META"' EXIT
ok=0; failed=0
check() { # config expected
  cfg=$1; expect=$2; log="$META/$cfg.log"; model=${cfg%%-*}.tla
  "$TLC" -workers "$WORKERS" -metadir "$META/$cfg" -config "$cfg.cfg" "$model" >"$log" 2>&1
  code=$?
  if tlc_expect "$log" "$code" "$cfg.cfg" "$expect"; then
    if [ "$got" = none ]; then echo "OK $cfg: no error"; else echo "OK $cfg: $got violated (expected)"; fi
    ok=$((ok+1))
  else
    echo "FAIL $cfg: got '${got:-error}', expected '$expect'"; sed -n '/^Error/,+3p' "$log" | head -5
    failed=$((failed+1))
  fi
}
check Onboarding-safety none
check Onboarding-live none
check Onboarding-nofinishguard FinishOnlyWhenReady
check Onboarding-noback PastPermissionsOnlyWhenGranted
check Onboarding-doubledownload AtMostOneDownload
check Onboarding-stalereset NoResetOfWorkingGrant
check Onboarding-relaunchloop RelaunchBounded
check Onboarding-nofix Termination
check MeetingTitle-safety none
check MeetingTitle-live none
check MeetingTitle-noapply NamedAfterSummary
check MeetingTitle-nocas UserWins
check MeetingTitle-staleread UserWins
echo "check: $ok ok, $failed failed"
[ "$failed" -eq 0 ]
