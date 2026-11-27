#!/usr/bin/env bash
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Stop the demo started by examples/venue-monitor/start-demo.sh: stop the RTSP stream, then
# stop the app tier while leaving the model serving running to avoid model reload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "stopping RTSP stream…"
bash "$SCRIPT_DIR/stop-stream.sh" || true

echo "stopping app tier (keeping the model serving warm)…"
bash "$REPO_DIR/setup_docker.sh" --light-down || true
