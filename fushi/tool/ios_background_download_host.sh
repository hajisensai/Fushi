#!/usr/bin/env bash
# BUG-3887：iOS 词典包后台下载的宿主侧验证（Mac 上、在 fushi/ 目录下跑）。
#
#   bash tool/ios_background_download_host.sh <模拟器 udid> <native|dio|restart>
#
# 1. 起一个限速 HTTP 服务器（/small.bin、/big.bin 限速、其余 404），逐秒记录发出的字节；
# 2. 跑 integration_test/ios_background_download_itest.dart；
# 3. 测试打印 BG_DL_GO_BACKGROUND 时把「设置」拉到前台（本 app 进后台），BG_SECONDS 秒后切回；
# 4. 统计后台窗口内服务器发出的字节：native 应持续在发，dio（对照组）应基本停住。
set -u
UDID=${1:?udid}
KIND=${2:-native}
PORT=${BG_DL_PORT:-8765}
RATE=${BG_DL_RATE:-2097152}            # 字节/秒
BIG=${BG_DL_BIG_BYTES:-62914560}       # 60 MiB
BG_SECONDS=${BG_SECONDS:-20}
OUT=${BG_DL_OUT:-/tmp/bgdl-$KIND}
export PATH=/opt/homebrew/bin:$HOME/.cargo/bin:$PATH

rm -rf "$OUT" && mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true

cat > "$OUT/server.py" <<'PY'
import http.server, os, socketserver, sys, threading, time
port, rate, big, log = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
lock = threading.Lock()
sent = {}
def record(n):
    with lock:
        sec = int(time.time())
        sent[sec] = sent.get(sec, 0) + n
def flusher():
    while True:
        time.sleep(1)
        with lock:
            items = sorted(sent.items()); sent.clear()
        with open(log, 'a') as f:
            for sec, n in items:
                f.write(f"{sec} {n}\n")
threading.Thread(target=flusher, daemon=True).start()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith('/small.bin'):
            size, throttle = 256 * 1024, False
        elif self.path.startswith('/big.bin'):
            size, throttle = big, True
        else:
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(size))
        self.end_headers()
        chunk = b'\0' * 65536
        left = size
        try:
            while left > 0:
                n = min(len(chunk), left)
                self.wfile.write(chunk[:n]); left -= n; record(n)
                if throttle: time.sleep(n / rate)
        except (BrokenPipeError, ConnectionResetError):
            pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
S(('0.0.0.0', port), H).serve_forever()
PY
python3 "$OUT/server.py" "$PORT" "$RATE" "$BIG" "$OUT/server.log" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT

if [ "$KIND" = restart ]; then
  # BUG-3887 续：进程被系统回收后新进程接着下。第一段下到一段后 kill -9 app（等同内存
  # 回收；不是 simctl terminate——那接近用户划掉，系统会取消后台任务），死亡窗口里服务器
  # 应仍在发字节；第二段重新拉起，必须接回同一个任务并完整落盘。
  DEAD_SECONDS=${DEAD_SECONDS:-15}
  flutter test integration_test/ios_background_download_itest.dart -d "$UDID" \
    --dart-define=BG_DL_BASE=http://127.0.0.1:$PORT \
    --dart-define=BG_DL_PHASE=restart-start \
    --dart-define=BG_DL_BIG_BYTES=$BIG > "$OUT/flutter-start.log" 2>&1 &
  TEST=$!
  DEAD_START=""
  while kill -0 $TEST 2>/dev/null; do
    if grep -q BG_DL_KILL_ME "$OUT/flutter-start.log"; then
      APP_PID=$(xcrun simctl spawn "$UDID" launchctl list | awk '/UIKitApplication:app\.fushi\.reader/ {print $1; exit}')
      echo "kill -9 app pid=$APP_PID"
      kill -9 "$APP_PID"
      DEAD_START=$(date +%s)
      break
    fi
    sleep 1
  done
  wait $TEST 2>/dev/null
  [ -n "$DEAD_START" ] || { echo "RUN_END kind=restart never reached BG_DL_KILL_ME"; exit 1; }
  sleep "$DEAD_SECONDS"
  DEAD_END=$(date +%s)
  flutter test integration_test/ios_background_download_itest.dart -d "$UDID" \
    --dart-define=BG_DL_BASE=http://127.0.0.1:$PORT \
    --dart-define=BG_DL_PHASE=restart-resume \
    --dart-define=BG_DL_BIG_BYTES=$BIG > "$OUT/flutter-resume.log" 2>&1
  STATUS=$?
  sleep 2
  grep -h "BG_DL_RECOVERED\|BG_DL_RESUMED" "$OUT/flutter-resume.log"
  tail -5 "$OUT/flutter-resume.log"
  awk -v a="$DEAD_START" -v b="$DEAD_END" '$1>=a && $1<b {s+=$2; n++} END {printf "DEAD_WINDOW bytes=%d seconds_with_data=%d window=%d\n", s, n, b-a}' "$OUT/server.log"
  # 从头再下会让服务器总发送量接近 2×BIG；接管应只略多于 1×BIG。
  awk '{s+=$2} END {printf "SERVER_TOTAL bytes=%d\n", s}' "$OUT/server.log"
  echo "RUN_END kind=restart exit=$STATUS"
  exit $STATUS
fi

flutter test integration_test/ios_background_download_itest.dart -d "$UDID" \
  --dart-define=BG_DL_BASE=http://127.0.0.1:$PORT \
  --dart-define=BG_DL_TRANSPORT=$KIND \
  --dart-define=BG_DL_BIG_BYTES=$BIG > "$OUT/flutter.log" 2>&1 &
TEST=$!

BG_START=""
while kill -0 $TEST 2>/dev/null; do
  if [ -z "$BG_START" ] && grep -q BG_DL_GO_BACKGROUND "$OUT/flutter.log"; then
    xcrun simctl launch "$UDID" com.apple.Preferences > /dev/null
    BG_START=$(date +%s)
    echo "background at $BG_START"
    sleep "$BG_SECONDS"
    BG_END=$(date +%s)
    xcrun simctl launch "$UDID" app.fushi.reader > /dev/null
    echo "foreground at $BG_END"
  fi
  sleep 1
done
wait $TEST
STATUS=$?
sleep 2
tail -5 "$OUT/flutter.log"
if [ -n "$BG_START" ]; then
  # 切走后先给 5 秒（系统挂起 app 需要几秒），再看窗口内的发送量。
  awk -v a=$((BG_START + 5)) -v b="$BG_END" '$1>=a && $1<b {s+=$2; n++} END {printf "BG_WINDOW bytes=%d seconds_with_data=%d window=%d\n", s, n, b-a}' "$OUT/server.log"
else
  echo "BG_WINDOW never entered background"
fi
echo "RUN_END kind=$KIND exit=$STATUS"
exit $STATUS
