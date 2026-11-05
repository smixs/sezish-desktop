#!/bin/sh
# Source from a check script. A verdict requires both TLC's exit class and its first error.
# Outputs got for callers' statistics; never infers a successful run from text alone.
tlc_expect() { # log exit-code config expected [first admissions] [bfs|simulate]
  result_log=$1; result_code=$2; result_cfg=$3; result_expect=$4
  result_admissions=${5:-}; result_mode=${6:-bfs}
  if [ -n "${LOG_DIR:-}" ]; then
    mkdir -p "$LOG_DIR" && cp "$result_log" "$LOG_DIR/$(basename "$result_log")" || return 1
  fi
  got=
  first_error=$(sed -n '/^Error:/{p;q;}' "$result_log")
  case "$result_code" in
    0)
      [ -z "$first_error" ] || return 1
      if grep -q '^Model checking completed\. No error has been found\.' "$result_log"; then
        got=none
      elif [ "$result_mode" = simulate ] &&
           grep -q '^Progress: .* states checked\.' "$result_log" &&
           grep -q '^Finished in ' "$result_log"; then
        got=none
      else return 1; fi
      ;;
    12)
      got=$(printf '%s\n' "$first_error" | sed -n 's/^Error: Invariant \([A-Za-z0-9_]*\) is violated\..*/\1/p')
      [ -n "$got" ] || return 1
      ;;
    13)
      case "$first_error" in 'Error: Temporal properties were violated.'*) ;; *) return 1;; esac
      # TLC names no property in this message: the configuration must identify exactly one.
      got=$(awk '/^PROPERT(Y|IES)[ \t]/ {
        sub(/\\\*.*/, ""); for (i=2; i<=NF; i++) {name=$i; count++}
      } END {if (count == 1 && name ~ /^[A-Za-z][A-Za-z0-9_]*$/) print name}' "$result_cfg")
      [ -n "$got" ] || return 1
      ;;
    *) return 1;;
  esac
  [ "$got" = "$result_expect" ] || return 1
  if [ -n "$result_admissions" ]; then
    last_admitted=$(sed -n 's/.*admitted = //p' "$result_log" | tail -1)
    size=$(printf '%s\n' "$last_admitted" | awk '{gsub(/[{}[:space:]]/, ""); print length($0) ? split($0, a, ",") : 0}')
    [ "$size" -eq "$result_admissions" ] || return 1
  fi
}
