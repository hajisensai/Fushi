#!/usr/bin/env python3
"""把 ACOUSTID_API_KEY 写成 fushi/lib/src/media/music/acoustid_secret.dart。

与 write_opensubtitles_key.py 同理：目标文件**不在** analyzer.exclude 里，必须写
单引号 Dart 字面量（双引号触发 prefer_single_quotes → CI analyze 门失败）。
key 走环境变量而不是 argv，避免出现在进程列表里；没给 key 时不动入库空占位。
"""

import os
import sys

# 与入库占位逐字一致：只替换 const 那一行的值，注释保持不变。
_HEADER = (
    "/// AcoustID application API key supplied by CI, never a user's personal credential.\n"
    "/// An empty source stub keeps unconfigured builds unavailable.\n"
)
_CONST = "const String kBuiltinAcoustidApiKey = '%s';\n"


def dart_single_quoted(value: str) -> str:
    """转义成可放进 Dart **单引号**字符串的内容（与 write_opensubtitles_key.py 同一实现）。

    反斜杠、单引号要转义；单引号字符串里 `$` 仍是插值符，也必须转义，
    否则形如 `abc$id` 的 key 会被当成变量插值、编译失败。
    """
    return (
        value.replace('\\', r'\\')
        .replace("'", r"\'")
        .replace('$', r'\$')
    )


def main() -> int:
    dst = sys.argv[1]
    key = os.environ.get('ACOUSTID_API_KEY', '')
    if not key:
        return 0
    with open(dst, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(_HEADER)
        handle.write(_CONST % dart_single_quoted(key))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
