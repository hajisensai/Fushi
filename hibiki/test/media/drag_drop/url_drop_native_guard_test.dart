import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1306 原生守卫：URL 拖放的原生抽取（Windows CFSTR_INETURLW / macOS public.url /
/// Linux text/uri-list 里的 http(s)）无 headless 测试——要真 OS 拖放 + CI Build Desktop
/// 编译才验得了。这里扫 vendored fork（third_party/desktop_drop）源码，钉死三平台各自的
/// URL 抽取分支不被回退（否则浏览器地址栏拖进来的链接又会被原生静默丢弃）。
File _find(List<String> candidates) => candidates.map(File.new).firstWhere(
      (File f) => f.existsSync(),
      orElse: () => File(candidates.first),
    );

void main() {
  test('Windows fork extracts CFSTR_INETURLW on URL drag (TODO-1306)', () {
    final File f = _find(<String>[
      '../third_party/desktop_drop/windows/desktop_drop_plugin.cpp',
      'third_party/desktop_drop/windows/desktop_drop_plugin.cpp',
    ]);
    expect(f.existsSync(), isTrue, reason: 'vendored windows plugin 缺失');
    final String src = f.readAsStringSync();
    expect(src.contains('TODO-1306'), isTrue);
    expect(src.contains('CFSTR_INETURLW'), isTrue,
        reason: '必须抽取浏览器 URL 拖放的规范剪贴板格式');
    expect(src.contains('ExtractDroppedUrl'), isTrue);
    // URL 分支必须喂给与文件路径同一条 performOperation 列表（无 CF_HDROP 才走）。
    expect(RegExp(r'if\s*\(list\.empty\(\)\)').hasMatch(src), isTrue,
        reason: 'URL 抽取应在无文件（空 CF_HDROP）时兜底');
  });

  test('macOS fork reads a non-file NSURL on URL drag (TODO-1306)', () {
    final File f = _find(<String>[
      '../third_party/desktop_drop/macos/Classes/DesktopDropPlugin.swift',
      'third_party/desktop_drop/macos/Classes/DesktopDropPlugin.swift',
    ]);
    expect(f.existsSync(), isTrue, reason: 'vendored macos plugin 缺失');
    final String src = f.readAsStringSync();
    expect(src.contains('TODO-1306'), isTrue);
    expect(src.contains('PasteboardType.URL'), isTrue,
        reason: '必须注册 web-URL 拖放类型（public.url）');
    expect(src.contains('NSURL(from:'), isTrue);
    expect(src.contains('isFileURL'), isTrue,
        reason: '必须用 !isFileURL 防止文件 URL 被重复计数');
  });

  test('Linux channel preserves http(s) URIs on URL drag (TODO-1306)', () {
    final File f = _find(<String>[
      '../third_party/desktop_drop/lib/src/channel.dart',
      'third_party/desktop_drop/lib/src/channel.dart',
    ]);
    expect(f.existsSync(), isTrue, reason: 'vendored channel.dart 缺失');
    final String src = f.readAsStringSync();
    expect(src.contains('TODO-1306'), isTrue);
    // performOperation_linux 绝不能对 http(s) URI 调 toFilePath()（会抛异常被丢弃），
    // 必须原样保留。
    expect(src.contains("uri.scheme == 'http'"), isTrue,
        reason: 'performOperation_linux 必须保留 http(s) URI，不能丢');
  });
}
