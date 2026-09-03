import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/android_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

import '../../helpers/source_guard.dart';

/// BUG-1767 守卫：漫画详情返回的是**增量**，条目身份（`url`）只能来自入参。
///
/// Mihon 扩展的 `mangaDetailsParse` 会 `SManga.create()` 一个只填元数据的新对象，
/// 从不回填 `url`（上游官方 app 也从不读它）。而 `SMangaImpl.url` / `title` 是
/// `lateinit var`，于是两个后端各自暴露了同一个错误假设：
///
/// * Android 原生桥直接读 `update.url` → `UninitializedPropertyAccessException`
///   → 兜底成 `RUNTIME_FAILURE`，表现为「漫画列表能开、点进作品必报错」；
/// * 桌面 sidecar 用 `runCatching{}.getOrDefault("")` 读，不崩但把 `url` 变成空串，
///   接下来拿空 url 去拉章节。
///
/// 所以身份收敛统一放在 Dart 侧（[MihonManga.mergedWithDetails]），原生侧的合并
/// 只是让它在崩之前就不再读那个字段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('详情增量合并', () {
    const MihonManga base = MihonManga(
      url: '/manga/one-piece-gakuen',
      title: 'ONE PIECE学園',
      coverUrl: 'https://example.test/cover.jpg',
      status: 1,
    );

    test('缺 url 的增量不会把身份抹掉', () {
      const MihonManga update = MihonManga(
        url: '',
        title: 'ONE PIECE学園',
        author: '尾田栄一郎',
        description: '本文',
        initialized: true,
      );

      final MihonManga merged = base.mergedWithDetails(update);

      expect(merged.url, '/manga/one-piece-gakuen');
      expect(merged.author, '尾田栄一郎');
      expect(merged.description, '本文');
      expect(merged.initialized, isTrue);
    });

    test('增量没带的字段回落到已知值，带了的覆盖', () {
      const MihonManga update = MihonManga(
        url: '/somewhere/else',
        title: '',
        genre: 'Comedy',
        status: 2,
      );

      final MihonManga merged = base.mergedWithDetails(update);

      // url 永远不被详情更新，哪怕增量里非空。
      expect(merged.url, '/manga/one-piece-gakuen');
      expect(merged.title, 'ONE PIECE学園');
      expect(merged.coverUrl, 'https://example.test/cover.jpg');
      expect(merged.genre, 'Comedy');
      expect(merged.status, 2);
    });
  });

  test('原生桥回传空 url 时 getDetails 仍然保住入参身份', () async {
    const MethodChannel channel = MethodChannel('app.fushi.reader/mihon');
    Map<Object?, Object?>? sentDetailArguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      sentDetailArguments = call.arguments as Map<Object?, Object?>;
      return <String, Object?>{
        // 桌面 sidecar 对未初始化 lateinit 的真实产物就是空串。
        'url': '',
        'title': 'ONE PIECE学園',
        'author': '尾田栄一郎',
        'initialized': true,
      };
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final MihonManga details = await AndroidMihonRuntime().getDetails(
      const MihonExtensionRef(
        packageName: 'eu.kanade.tachiyomi.extension.ja.mangamura',
        apkPath: 'extensions/mangamura.ext',
      ),
      const MihonSource(
        extensionPackage: 'eu.kanade.tachiyomi.extension.ja.mangamura',
        id: '1006356371941619891',
        name: 'Manga Mura',
        language: 'ja',
        baseUrl: 'https://mangamura.test',
      ),
      const MihonManga(
        url: '/manga/one-piece-gakuen',
        title: 'ONE PIECE学園',
      ),
    );

    expect(details.url, '/manga/one-piece-gakuen');
    expect(details.author, '尾田栄一郎');
    expect(
      (sentDetailArguments!['mangaData']! as Map<Object?, Object?>)['url'],
      '/manga/one-piece-gakuen',
    );
  });

  group('Android 原生桥的详情合并', () {
    late final String handler = File(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt',
    ).readAsStringSync();
    late final String modelBridge = File(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/MihonModelBridge.kt',
    ).readAsStringSync();

    test('MihonModelBridge 提供 mergedWithDetails', () {
      expect(
        maskComments(modelBridge).contains('fun SManga.mergedWithDetails('),
        isTrue,
        reason: 'MihonModelBridge.kt 少了 mergedWithDetails；'
            '详情增量就会重新被当成完整条目读 lateinit url。',
      );
    });

    test('getDetailsManga 不读详情结果的 url，改走 mergedWithDetails', () {
      // 必须先去注释：本文件自己就在注释里写过 `update.url`，
      // 直扫原文会被自己的注释骗成假红/假绿。
      final String branch = maskComments(_getDetailsMangaBranch(handler));
      expect(
        branch.contains('mergedWithDetails'),
        isTrue,
        reason: 'getDetailsManga 分支没有调用 mergedWithDetails：\n$branch',
      );
      expect(
        RegExp(r'(result|update|detailedManga)\s*\.\s*url').hasMatch(branch),
        isFalse,
        reason: 'getDetailsManga 分支又开始读详情结果的 url 了，'
            '那是未初始化的 lateinit，必报 RUNTIME_FAILURE：\n$branch',
      );
    });
  });

  test('原生桥失败时必须回传真实原因而不是固定文案', () {
    final String handler = File(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt',
    ).readAsStringSync();
    expect(
      maskComments(handler).contains('catch (_: Throwable)'),
      isFalse,
      reason: 'MethodChannel 兜底又开始丢弃 Throwable 了；'
          '扩展失败原因只存在于 cause 链，丢了就无从诊断。',
    );
    expect(
      maskComments(handler).contains('describeCauseChain('),
      isTrue,
      reason: '兜底分支必须把 cause 链渲染进 message。',
    );
    expect(
      maskComments(handler).contains('diagnosticDetails('),
      isTrue,
      reason: '兜底分支必须把堆栈放进 MethodChannel 的 details 字段。',
    );
  });
}

/// 截出 `"getDetailsManga" ->` 到下一个 `"..." ->` 之间的分支体。
String _getDetailsMangaBranch(String source) {
  const String marker = '"getDetailsManga" ->';
  final int start = source.indexOf(marker);
  if (start < 0) {
    fail('MihonChannelHandler.kt 里找不到 "getDetailsManga" 分支');
  }
  final int next =
      source.indexOf(RegExp('"[A-Za-z]+" ->'), start + marker.length);
  return source.substring(start, next < 0 ? source.length : next);
}
