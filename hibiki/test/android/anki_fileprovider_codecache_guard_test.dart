import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// BUG-474 (TODO-1012) source-scan guard: AnkiDroid 制卡时把词典 SVG 外字媒体写到
/// `Directory.systemTemp/anki-media`，在 Android 上 `Directory.systemTemp` 解析到
/// `/data/data/<pkg>/code_cache`（JVM `java.io.tmpdir`）。`AnkiChannelHandler` 的
/// `addFileToMedia` 调 `FileProvider.getUriForFile`，而 AndroidX core 1.13.1 的
/// FileProvider 没有 `code-cache-path` 标签（仅 root/files/cache/external*），故 provider
/// 的 `provider_paths.xml` 若不声明覆盖 `code_cache` 的根，就会抛
/// `IllegalArgumentException: Failed to find configured root that contains …code_cache…`，
/// SVG 外字图无法附到 Anki 卡片。
///
/// 根因修复（root fix）：在 `provider_paths.xml` 用 `<files-path path="../code_cache">`，
/// FileProvider addRoot 时对 `getFilesDir()/../code_cache` 取 getCanonicalFile() →
/// 规范化成 `/data/data/<pkg>/code_cache`，精确覆盖该根（不暴露整个设备根 root-path）。
///
/// 真机 FileProvider 解析跑在 Android 原生层（这里跑不了），故守 *配置机制*：若
/// `provider_paths.xml` 不再声明能覆盖 code_cache 的根，或写入目录脱离 code_cache 假设，
/// AnkiDroid 外字制卡会再次静默断裂，本测试转红。
void main() {
  // Tests run with CWD = `hibiki/`.
  final File providerPaths = File(
    'android/app/src/main/res/xml/provider_paths.xml',
  );

  test('provider_paths.xml exists', () {
    expect(providerPaths.existsSync(), isTrue,
        reason: 'BUG-474 fix lives in this FileProvider path whitelist');
  });

  test('Anki dict media cache lives under code_cache (Directory.systemTemp)',
      () {
    // writer/reader 共用的缓存目录；最后一段是 anki-media，父目录即 systemTemp
    // （Android = code_cache）。这条断言把「写到 code_cache」这个前提钉死，
    // 一旦写入目录改走别处（如 getCacheDir），应同步更新 provider_paths.xml
    // 与本守卫，否则二者脱节。
    expect(ankiDictionaryMediaCacheDirPath().endsWith('anki-media'), isTrue,
        reason: 'AnkiDroid/AnkiConnect repo 与 writeDictionaryMediaCache 共用此目录');
  });

  test('provider_paths declares a root that covers code_cache', () {
    final String xml = providerPaths.readAsStringSync();
    // 容忍属性顺序/空白变化。
    final String compact = xml.replaceAll(RegExp(r'\s+'), ' ');

    // 覆盖 code_cache 的两种合法方案：
    //  (1) files-path 相对 `../code_cache`（精确、推荐，本次采用）；
    //  (2) root-path（覆盖整个设备根，含 code_cache，宽但有效）。
    final RegExp filesRelCodeCache = RegExp(
      r'<files-path[^>]*path="\.\./code_cache"',
    );
    final RegExp rootPath = RegExp(r'<root-path\b');

    expect(
      filesRelCodeCache.hasMatch(compact) || rootPath.hasMatch(compact),
      isTrue,
      reason: 'BUG-474: FileProvider 必须能解析 code_cache 下的文件，否则 getUriForFile '
          '对 …/code_cache/anki-media/*.svg 抛 "Failed to find configured root"，'
          'AnkiDroid 外字 SVG 制卡断裂。用 <files-path path="../code_cache"> 精确覆盖，'
          '或退而用 <root-path>。',
    );
  });
}
