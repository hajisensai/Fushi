import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/video_work_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2230 守卫：视频域「不用共享脚手架、直接裸 `Scaffold`」的页面，**每条渲染分支
/// 都必须留一个可见出口**。
///
/// 背景 —— 这是 BUG-2229 的同族。仓库里绝大多数页面走 `FushiPageScaffold` /
/// `FushiToolScaffold`，它们的 `_defaultLeading` 在 `Navigator.canPop()` 时**无条件**
/// 插一颗返回箭头（`fushi_material_components.dart`），所以天然安全；出问题的恰恰是
/// 视频域这几个绕过共享脚手架、自己拼 `Scaffold` 的页面 —— 它们的退出入口挂在
/// 「就绪」分支上（播放器内顶栏 / `_buildAppBar`），而**早退分支**（加载中 / 资源缺失）
/// 里那个顶栏根本没挂载。桌面端没有系统返回键，用户就被钉死在页面上。
/// 漫画页早就把这条立成规矩了：「出口不是内容的一部分，不随内容存亡」。
///
/// 这里测的是**行为**，不是文案：让底层 DB 真的抛异常，断言页面收敛到带返回键的
/// 终态，而不是永久转圈。
/// `_load()` 的第一跳就抛 —— 模拟并发下 sqlite 连接被毒化 / BUSY 这类真实失败。
class _ThrowingVideoBookRepository extends VideoBookRepository {
  const _ThrowingVideoBookRepository(super.db);

  @override
  Future<VideoBookRow?> getByBookUid(String bookUid) =>
      Future<VideoBookRow?>.error(StateError('simulated DB failure'));
}

void main() {
  late FushiDatabase db;
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hibiki_bug2230');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget wrap(Widget page) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (BuildContext _) => page),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

  /// `_load()` 连着 6 次 DB 读且是 fire-and-forget 的。从前它没有 try/catch：任意一次
  /// 抛出（并发下 sqlite BUSY、连接被毒化等）就让 `_loading` 永远为 true，页面停在
  /// **无 AppBar 的转圈**上 —— 无出口。现在异常必须收敛到「未找到」终态，且该终态
  /// 带返回键。
  ///
  /// 注入点用 override 过的 repository 直接抛，**不是**关掉数据库 —— 实测 close 之后
  /// 那几个读并不抛、而是落到 null，那样测出来的绿与 try/catch 有没有无关（恒真）。
  testWidgets(
      'VideoWorkDetailPage: a throwing load lands on an exitable state, not an '
      'endless spinner (BUG-2230)', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(VideoWorkDetailPage(
      database: db,
      repository: _ThrowingVideoBookRepository(db),
      workRef: const VideoWorkRef.book('video/boom'),
      onChanged: () {},
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 关键判据：页面**收敛到了「未找到」终态**。
    // 不能拿「屏幕上没有转圈」或「有 BackButton」当判据 —— 加载态用的是
    // `adaptiveIndicator`（未必是 CircularProgressIndicator），而加载态现在同样带
    // AppBar，两者在「有没有 try/catch」两种情况下都成立，是恒真断言。
    // 只有这句文案能区分「异常被收敛」和「永久卡在加载态」。
    expect(find.text(t.video_load_failed_not_found), findsOneWidget);
    // 且这一屏有可见的返回入口（AppBar 的自动 leading）。
    expect(find.byType(BackButton), findsOneWidget);

    // 点它必须真的退得出去。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(VideoWorkDetailPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  /// 加载态本身也必须有出口 —— 出口不随内容存亡。这一条走**源码守卫**而不是 widget
  /// 行为：加载态在 widget 环境里不可靠复现（in-memory DB 一帧内就完成，FutureBuilder
  /// 直接落到 done），而 `WebVideoFushiPage` 更是要真 WebView2 环境才起得来。守的
  /// 不变式很窄也很硬：**这两个文件里每一处 `return Scaffold(` 都必须带 `appBar:`。**
  ///
  /// 只守这两个文件，不扩到 `video_fushi_page.dart` —— 那一个是**另一种范式**
  /// （BUG-102：退出并进 media_kit 视频内顶栏，Scaffold 故意不挂 AppBar），
  /// 拿同一把尺子去量它只会得到错误结论。
  test('video pages that hand-roll Scaffold always ship an AppBar (BUG-2230)',
      () {
    const List<String> files = <String>[
      'lib/src/pages/implementations/video_work_detail_page.dart',
      'lib/src/pages/implementations/web_video_fushi_page.dart',
    ];
    final List<String> offenders = <String>[];
    int checked = 0;

    for (final String rel in files) {
      final File file = File(rel);
      expect(file.existsSync(), isTrue,
          reason: '$rel 不存在——守卫的语料没了，先修守卫再说');
      final List<String> lines = file.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (!RegExp(r'return (const )?Scaffold\(').hasMatch(lines[i])) continue;
        checked++;
        // 构造体前几行里必须出现 appBar:（它总排在 body 之前）。
        final int end = (i + 8) > lines.length ? lines.length : (i + 8);
        if (!lines.sublist(i, end).join('\n').contains('appBar:')) {
          offenders.add('$rel:${i + 1} → ${lines[i].trim()}');
        }
      }
    }

    // 语料自检：守卫必须真的扫到了东西，否则它恒真、等于没写。
    expect(checked, greaterThanOrEqualTo(4),
        reason: '只扫到 $checked 处 return Scaffold(，少于预期——'
            '文件结构变了，守卫可能已失效');
    expect(offenders, isEmpty,
        reason: '这些分支没有 AppBar = 桌面端没有退出入口（BUG-2229/2230 同族）：\n'
            '${offenders.join('\n')}');
  });
}
