#!/usr/bin/env bash
# Dummy-data scenario against the built bundle (run build_in_docker.sh first):
# generates an EPUB / PDF / CBZ / video+SRT / MP3 / Yomitan dict, starts the app
# under Xvfb with an isolated FUSHI_TEST_ROOT and drives it through fushi_cli.
#   bash tool/linux/scenario_in_docker.sh  -> build/linux-dist/scenario-<time>/{part1,part2,app}.log, shots/*.png
# The same part1/part2 scripts also run against a real desktop session:
#   APPDIR=<bundle> bash tool/linux/smoke/run_cli_smoke.sh   (app already running)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export MSYS_NO_PATHCONV=1
OUT="$ROOT/build/linux-dist/scenario-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
docker run --rm -v fushi-linux-src:/src -v "$ROOT/tool/linux/smoke:/scripts:ro" -v "$OUT:/out" \
  fushi-linux-build:trixie bash /scripts/docker_scenario.sh
grep -h '^STEP' "$OUT/part1.log" "$OUT/part2.log"
tail -n1 "$OUT/part2.log"
echo "logs + screenshots: $OUT"
