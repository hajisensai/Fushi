#!/usr/bin/env bash
# Flutter 3.47：Material / Cupertino 从 SDK 拆成独立 pub 包 material_ui / cupertino_ui。
# 本脚本把本仓（fushi/、packages/、third_party/ vendored 包）的 Dart 源码从
#   package:flutter/material.dart  -> package:material_ui/material_ui.dart
#   package:flutter/cupertino.dart -> package:cupertino_ui/cupertino_ui.dart
# 并保证用到它们的包 pubspec 里声明了依赖。可重复执行（幂等），合并其它
# 仍用旧 import 的分支后重跑一次即可收尾。
#
# 用法（仓库根，Git Bash）：
#   bash tool/migrate_design_widgets.sh            # 迁移 import + 补 pubspec 依赖
#   bash tool/migrate_design_widgets.sh --check    # 只报告还剩多少旧 import，非 0 退出
#   bash tool/migrate_design_widgets.sh --pub-get  # 迁移后顺带 flutter pub get
#
# 等价性：官方 `dart fix --apply --code=migrate_design_widgets` 对本仓做的就是
# 逐个 import URI 的原位替换（不排序、不动 show/hide/as），在 fushi_dictionary 上
# 实测 diff 与本脚本逐字一致；这里用 sed 是因为 dart fix 要把整个 fushi 包
# （1600+ 个文件）载进分析器，单次数 GB 内存、几分钟，而且不覆盖 tool/ 等
# 分析器排除的目录。想用官方工具交叉核对：在 fushi/ 下
#   dart fix --dry-run --code=migrate_design_widgets
# 应输出 "Nothing to fix!"。
#
# 刻意不迁移的位置：
#   - ci/patches/**   ：给 pub-cache 里未迁移的上游包打的补丁，必须跟上游原文一致；
#   - references/**   ：只读子模块；
#   - **/example/**   ：独立解析的示例工程，不在 workspace 里；
#   - build/、.dart_tool/。
# 少数 fushi 源码文件确需同时引用旧 SDK Material 类型（给未迁移的第三方包
# 传 flutter/material 的 ThemeData 等），它们用 `as legacy` 前缀导入，
# 本脚本只替换不带前缀的 import，所以不会碰它们（见
# fushi/test/build/design_widgets_import_guard_test.dart 白名单）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=apply
PUB_GET=0
for a in "$@"; do
  case "$a" in
    --check) MODE=check ;;
    --pub-get) PUB_GET=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 64 ;;
  esac
done

# 不带 `as` 前缀的旧 import（show/hide 组合子可跨行）。`as legacy` 这类刻意保留的不算。
LEGACY_IMPORT_RE="^import\s+'package:flutter/(material|cupertino)\.dart'(\s+(show|hide)\s[^;]*)?;"

candidate_files() {
  # 先用 grep 粗筛（快），再由 perl 按多行规则精确判定。
  grep -rlE --include='*.dart' "^import 'package:flutter/(material|cupertino)\.dart'" \
    fushi packages third_party 2>/dev/null |
    grep -vE '(^|/)(\.dart_tool|example)/|^fushi/build/|^(packages|third_party)/[^/]+/build/' || true
}

list_legacy_files() {
  local f
  while IFS= read -r f; do
    RE="$LEGACY_IMPORT_RE" perl -0ne 'exit(m{$ENV{RE}}m ? 0 : 1)' "$f" && printf '%s\n' "$f"
  done < <(candidate_files)
}

mapfile -t FILES < <(list_legacy_files)

if [[ "$MODE" == check ]]; then
  echo "legacy design-widget imports left: ${#FILES[@]} file(s)"
  [[ ${#FILES[@]} -gt 0 ]] && printf '  %s\n' "${FILES[@]}"
  [[ ${#FILES[@]} -eq 0 ]]
  exit $?
fi

echo "migrating ${#FILES[@]} file(s)"
if [[ ${#FILES[@]} -gt 0 ]]; then
  printf '%s\0' "${FILES[@]}" | xargs -0 -n 200 perl -0pi -e '
    s{^import(\s+)'"'"'package:flutter/material\.dart'"'"'((?:\s+(?:show|hide)\s[^;]*)?);}{import$1'"'"'package:material_ui/material_ui.dart'"'"'$2;}mg;
    s{^import(\s+)'"'"'package:flutter/cupertino\.dart'"'"'((?:\s+(?:show|hide)\s[^;]*)?);}{import$1'"'"'package:cupertino_ui/cupertino_ui.dart'"'"'$2;}mg;
  '
fi

# --- pubspec：凡是 Dart 源码引用了 material_ui / cupertino_ui 的包，都要直接声明依赖 ---
MATERIAL_UI_VERSION='^1.5.0'
CUPERTINO_UI_VERSION='^1.1.1'

ensure_dep() { # <pubspec> <pkg> <version>
  local pubspec="$1" pkg="$2" ver="$3"
  if grep -qE "^  ${pkg}:" "$pubspec"; then return 0; fi
  # 插在 dependencies: 下第一条 `  flutter:\n    sdk: flutter` 之后。
  awk -v pkg="$pkg" -v ver="$ver" '
    BEGIN { indeps = 0; done = 0; pending = 0 }
    {
      print
      if ($0 ~ /^dependencies:/) { indeps = 1; next }
      if (indeps && $0 ~ /^[^ #]/) { indeps = 0 }
      if (!done && indeps && $0 ~ /^  flutter:[ ]*$/) { pending = 1; next }
      if (pending && $0 ~ /^    sdk: flutter/) {
        print "  " pkg ": " ver; done = 1; pending = 0
      }
    }' "$pubspec" > "$pubspec.tmp" && mv "$pubspec.tmp" "$pubspec"
  echo "  + $pkg $ver -> $pubspec"
}

for pubspec in fushi/pubspec.yaml packages/*/pubspec.yaml third_party/*/pubspec.yaml; do
  dir="$(dirname "$pubspec")"
  [[ -d "$dir/lib" || -d "$dir/test" ]] || continue
  # 只看 lib/：dev 依赖面（test/）跟随主包；fushi 两者都已直接依赖。
  if grep -rqE --include='*.dart' "^import 'package:material_ui/" "$dir/lib" "$dir/test" "$dir/integration_test" 2>/dev/null; then
    ensure_dep "$pubspec" material_ui "$MATERIAL_UI_VERSION"
  fi
  if grep -rqE --include='*.dart' "^import 'package:cupertino_ui/" "$dir/lib" "$dir/test" "$dir/integration_test" 2>/dev/null; then
    ensure_dep "$pubspec" cupertino_ui "$CUPERTINO_UI_VERSION"
  fi
done

mapfile -t LEFT < <(list_legacy_files)
echo "legacy design-widget imports left: ${#LEFT[@]}"

if [[ $PUB_GET -eq 1 ]]; then
  (cd fushi && flutter pub get)
fi
