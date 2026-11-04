#!/usr/bin/env bash
# macOS 小组件扩展（fushi.app/Contents/PlugIns/FushiWidgets.appex）的签名补丁。
#
# 为什么需要：release-desktop.yml 的 macOS 链路会多次 `codesign --force --deep --sign -`
# 整个 app（拷进 ffmpeg / Mihon 运行时之后），Developer ID 那一步又逐个重签 Mach-O ——
# 两种重签都**不带 entitlements**，扩展的 app-sandbox / application-groups 随之丢失，而
# WidgetKit 拒载不在沙盒里的扩展。所以每次整包重签之后、签外层 app 之前，用本脚本把扩展
# 连同它的 entitlements 重签一遍。
#
#   macos_widgets_sign.sh entitlements <src.entitlements> <group> <out>
#       把 `$(FUSHI_APP_GROUP)` 展开成 <group> 写到 <out>（codesign 不展开 Xcode 变量）。
#   macos_widgets_sign.sh appex <fushi.app> <group> <codesign 参数…>
#       用展开后的扩展 entitlements 重签 appex；codesign 参数原样透传（--sign / --keychain /
#       --options runtime / --timestamp …）。app 里没有扩展时什么也不做。
#
# <group>：Developer ID = "<TEAM_ID>.app.fushi.reader"；ad-hoc = "app.fushi.reader"
# （与 Xcode 在没有 Team 时展开 `$(TeamIdentifierPrefix)app.fushi.reader` 的结果一致）。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fushi_root="$(cd "$here/../.." && pwd)"

expand() {
  local src="$1" group="$2" out="$3"
  sed "s|\$(FUSHI_APP_GROUP)|$group|g" "$src" > "$out"
  if grep -q '\$(' "$out"; then
    echo "error: unexpanded build variable left in $out" >&2
    exit 1
  fi
  plutil -lint "$out" > /dev/null
}

cmd="${1:-}"
shift || true
case "$cmd" in
  entitlements)
    [ "$#" -eq 3 ] || { echo "usage: $0 entitlements <src> <group> <out>" >&2; exit 64; }
    expand "$1" "$2" "$3"
    ;;
  appex)
    [ "$#" -ge 3 ] || { echo "usage: $0 appex <fushi.app> <group> <codesign args…>" >&2; exit 64; }
    app="$1"
    group="$2"
    shift 2
    appex="$app/Contents/PlugIns/FushiWidgets.appex"
    if [ ! -d "$appex" ]; then
      echo "no FushiWidgets.appex in $app, nothing to sign"
      exit 0
    fi
    ent="$(mktemp -t fushi-widgets-ent).plist"
    expand "$fushi_root/macos/FushiWidgets/FushiWidgets.entitlements" "$group" "$ent"
    codesign --force --entitlements "$ent" "$@" "$appex"
    codesign --verify --strict --verbose=2 "$appex"
    codesign --display --entitlements - "$appex" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' || {
      echo "error: FushiWidgets.appex lost its sandbox entitlement" >&2
      exit 1
    }
    rm -f "$ent"
    echo "signed FushiWidgets.appex (group $group)"
    ;;
  *)
    echo "usage: $0 entitlements|appex …" >&2
    exit 64
    ;;
esac
