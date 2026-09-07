#!/usr/bin/env python3
"""把 OPENSUBTITLES_API_KEY 写成 opensubtitles_default_key.dart。

为什么不像 google_oauth_secret.dart 那样直接 `json.dumps` 打一行：
json.dumps 产出的是**双引号** Dart 字面量，而本文件**不在**
fushi/analysis_options.yaml 的 analyzer.exclude 里，双引号会触发
prefer_single_quotes（info）——CI 的 analyze 门把 info 也当失败（exit 1），
于是每个带 OPENSUBTITLES_API_KEY secret 的 run 都必红。
google_oauth_secret.dart / log_upload_secret.dart 能用双引号，只因为那两个
文件在 exclude 列表里；别把它们的写法照抄到不在 exclude 的文件上。

key 走环境变量而不是 argv，避免出现在进程列表里。
"""

import os
import sys

# 与入库占位逐字一致：CI 只替换 const 那一行的值，注释保持不变。
_HEADER = (
    "/// Application API key supplied by CI, never a user's personal credential.\n"
    "/// An empty source stub keeps unconfigured builds unavailable.\n"
)
_CONST = "const String kBuiltinOpenSubtitlesApiKey = '%s';\n"


def dart_single_quoted(value: str) -> str:
    """转义成可放进 Dart **单引号**字符串的内容。

    单引号字符串不做转义序列以外的解释，但 `$` 仍是插值符，必须一起转义，
    否则形如 `abc$id` 的 key 会被当成变量插值、编译失败。
    """
    return (
        value.replace('\\', r'\\')
        .replace("'", r"\'")
        .replace('$', r'\$')
    )


def main() -> int:
    dst = sys.argv[1]
    key = os.environ.get('OPENSUBTITLES_API_KEY', '')
    if not key:
        return 0
    with open(dst, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(_HEADER)
        handle.write(_CONST % dart_single_quoted(key))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
