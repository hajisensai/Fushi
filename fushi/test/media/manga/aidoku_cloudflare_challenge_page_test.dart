import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_cloudflare_challenge_page.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';

/// BUG-1876 审查修复：过盾页「解完」的判据是出现一个**值不同于 jar 现存条目**
/// 的 `cf_clearance`——共享 cookie 存储里的陈旧 cookie 不能秒判成功；持久化
/// 成功后才置完成态；关闭按钮永远可退出。
///
/// 内存 jar 测试替身：widget 测试跑在 FakeAsync 里，真实文件 IO 永远等不到
/// 完成，用无 IO 的覆写把页面与磁盘解耦。
class _MemoryJar extends AidokuCookieJar {
  _MemoryJar() : super(File('unused-by-memory-jar'));

  String? clearanceValue;
  bool failPersist = false;
  int replaceCalls = 0;

  @override
  Future<void> ensureLoaded() async {}

  @override
  String? clearanceValueFor(Uri url) => clearanceValue;

  @override
  Future<void> replaceForHost(String host, List<AidokuCookie> fresh) async {
    replaceCalls++;
    if (failPersist) {
      throw const FileSystemException('disk full');
    }
    for (final AidokuCookie cookie in fresh) {
      if (cookie.name == kCloudflareClearanceCookie) {
        clearanceValue = cookie.value;
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Uri challengeUrl = Uri.parse('https://mangafire.to/filter?keyword=x');

  Cookie clearance(String value) => Cookie(
    name: kCloudflareClearanceCookie,
    value: value,
    domain: '.mangafire.to',
    path: '/',
    isSecure: true,
  );

  Future<bool? Function()> openPage(
    WidgetTester tester, {
    required _MemoryJar jar,
    required Future<List<Cookie>> Function(WebUri url) cookieReader,
  }) async {
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => AidokuCloudflareChallengePage(
                      challengeUrl: challengeUrl,
                      jar: jar,
                      pollInterval: const Duration(milliseconds: 50),
                      cookieReader: cookieReader,
                      webViewBuilder: (_) => const SizedBox.expand(),
                    ),
                    fullscreenDialog: true,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => popped;
  }

  testWidgets(
    'a stale clearance equal to the jar entry never closes the page',
    (WidgetTester tester) async {
      final _MemoryJar jar = _MemoryJar()..clearanceValue = 'stale';
      final bool? Function() popped = await openPage(
        tester,
        jar: jar,
        cookieReader: (_) async => <Cookie>[clearance('stale')],
      );

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AidokuCloudflareChallengePage), findsOneWidget);
      expect(popped(), isNull);
      expect(jar.replaceCalls, 0);
    },
  );

  testWidgets('a fresh clearance updates the jar and pops true', (
    WidgetTester tester,
  ) async {
    final _MemoryJar jar = _MemoryJar()..clearanceValue = 'stale';
    final bool? Function() popped = await openPage(
      tester,
      jar: jar,
      cookieReader: (_) async => <Cookie>[clearance('freshly-solved')],
    );

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(popped(), isTrue);
    expect(find.byType(AidokuCloudflareChallengePage), findsNothing);
    expect(jar.clearanceValue, 'freshly-solved');
  });

  testWidgets('persist failure keeps the page open and retries next poll', (
    WidgetTester tester,
  ) async {
    final _MemoryJar jar = _MemoryJar()..failPersist = true;
    final bool? Function() popped = await openPage(
      tester,
      jar: jar,
      cookieReader: (_) async => <Cookie>[clearance('freshly-solved')],
    );

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AidokuCloudflareChallengePage), findsOneWidget);
    expect(popped(), isNull);
    expect(jar.replaceCalls, greaterThan(1)); // 每轮轮询都在重试持久化

    // 磁盘恢复后下一轮补写成功、正常收尾。
    jar.failPersist = false;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(popped(), isTrue);
    expect(jar.clearanceValue, 'freshly-solved');
  });

  testWidgets('the close button pops false and stops the page', (
    WidgetTester tester,
  ) async {
    final _MemoryJar jar = _MemoryJar();
    final bool? Function() popped = await openPage(
      tester,
      jar: jar,
      cookieReader: (_) async => const <Cookie>[],
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(popped(), isFalse);
    expect(find.byType(AidokuCloudflareChallengePage), findsNothing);
  });
}
