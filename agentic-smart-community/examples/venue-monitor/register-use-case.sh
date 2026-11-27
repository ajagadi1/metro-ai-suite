#!/usr/bin/env bash
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Register (or update) the venue_monitor task with multilevel-video-understanding.
# Called by start-demo.sh. Env: PROMPT_LANG=en|zh (default en), SUMMARY_URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_URL="${SUMMARY_URL:-http://localhost:8192}"
PROMPT_LANG="${PROMPT_LANG:-en}"
TASK="venue_monitor"
PROMPT_FILE="$SCRIPT_DIR/prompts/$TASK.$PROMPT_LANG.txt"

command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }
[[ -f "$PROMPT_FILE" ]] || { echo "unsupported PROMPT_LANG=$PROMPT_LANG (expected en or zh): $PROMPT_FILE not found" >&2; exit 1; }

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
jq -Rs --arg name "$TASK" '{task_name: $name, mode: "full", content: {text: .}}' "$PROMPT_FILE" >"$BODY"

register() {
  local code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$SUMMARY_URL/v1/tasks" \
    -H "Content-Type: application/json" --data-binary @"$BODY")" || return 1
  case "$code" in
    2??) echo "  → $TASK registered ($PROMPT_LANG)" ;;
    409)
      curl -fsS --max-time 10 -X PATCH "$SUMMARY_URL/v1/tasks/$TASK" \
        -H "Content-Type: application/json" --data-binary @"$BODY" >/dev/null || return 1
      echo "  → $TASK updated ($PROMPT_LANG)" ;;
    *) echo "  unexpected HTTP $code from $SUMMARY_URL/v1/tasks" >&2; return 1 ;;
  esac
}

echo "registering use case at $SUMMARY_URL…"
for attempt in $(seq 1 10); do
  register && exit 0
  echo "  summary service not ready (attempt $attempt/10) — retrying in 3s…" >&2
  sleep 3
done
echo "failed to register $TASK" >&2
exit 1
