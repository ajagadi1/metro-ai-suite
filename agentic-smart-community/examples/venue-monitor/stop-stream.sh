#!/usr/bin/env bash
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Stop the RTSP stream and its MediaMTX server.
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.run"

for name in ffmpeg mediamtx; do
  pidfile="$RUN_DIR/$name.pid"
  [[ -f "$pidfile" ]] || continue
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$pid" 2>/dev/null || true
    echo "stopped $name (pid $pid)"
  fi
  rm -f "$pidfile"
done
