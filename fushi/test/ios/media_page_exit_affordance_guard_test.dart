import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// BUG-2331 源码扫描守卫：**媒体页的「离开」不许绑在「一次数据库写入成功」上**，
/// 而**出口不许是内容的一部分**。
///
/// 背景（为什么这条守卫只能是源码扫描）：小说 / 漫画 / PDF 三个阅读页都被
/// `PopScope(canPop: false)` 包着自管退出，而 `canPop: false` 会同时关掉 iOS 的
/// Cupertino 侧滑返回——iOS 又没有系统返回键，于是这些页面在 iOS 上**唯一**的出口
/// 就是页内那颗返回键走的 `onPopInvokedWithResult` 回调。旧写法是
/// `final bool shouldPop = await onWillPop(); ... navigator.pop();`：`onWillPop`
/// 里是位置 flush + `closeMedia` 两笔 drift 写，而一条 `SQLITE_BUSY` 后未 reset 的
/// 写语句能让整条连接上每一次 COMMIT 都抛错（`video_exit_flush.dart` 记的
/// 2026-09-04 真机案例），那个 await 一挂住 `pop()` 就永远到不了，用户只能杀进程。
/// 正确口径是 [exitAfterPersist]（BUG-2119）：同步发起落库、**无条件**立刻退出。
///
/// 这两件事都发生在真机的慢/坏路径上（损坏的 EPUB、卡住的 sqlite 连接），widget
/// 测试造不出来；能守住的是**代码形状**这个契约。
void main() {
  // 测试运行时 CWD = `fushi/`。
  final Directory libDir = Directory('lib');

  List<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();

  test('扫描规模哨兵：lib/ 确实被枚举到了', () {
    expectScanScale(dartFiles().length,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
  });

  test('没有任何页面把 pop 排在 await onWillPop() 之后', () {
    // `onWillPop` 的定义处（BaseSourcePage）自然含这个名字，按路径豁免。
    const String definitionPath = 'base_source_page.dart';
    final List<String> offenders = <String>[];
    for (final File file in dartFiles()) {
      if (file.path.endsWith(definitionPath)) {
        continue;
      }
      // 只看真代码：注释里引用旧写法（本次修复就在几处注释里写明了它长什么样）
      // 不算违规，否则这条守卫会把解释自己的文字判成回归。剥离走统一入口
      // `helpers/source_guard.dart`（等长掩码，行式规则挡不住块注释）。
      final String code = maskComments(file.readAsStringSync());
      if (code.contains('await onWillPop()')) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'BUG-2331：退出不能等落库。`await onWillPop()` 一旦挂住，'
          '`canPop: false` 下的 iOS 页面就没有任何出口了（没有系统返回键，'
          '侧滑也被 canPop 关掉）。改用 exitAfterPersist(persist: onWillPop, ...)。',
    );
  });

  test('三个自管退出的阅读页都走 exitAfterPersist', () {
    const List<String> selfManagedExitPages = <String>[
      'lib/src/pages/implementations/reader_fushi_page.dart',
      'lib/src/pages/implementations/reader_pdf_page.dart',
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ];
    for (final String path in selfManagedExitPages) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path 应存在（守卫的枚举面）');
      final String source = file.readAsStringSync();
      // 这三页都用 `PopScope(canPop: false)` 自管退出；只要还这么写，就必须用
      // 不等落库的退出原语。
      expect(
        source.contains('canPop: false'),
        isTrue,
        reason: '$path 不再自管退出的话，请连同本守卫一起更新',
      );
      expect(
        source.contains('exitAfterPersist('),
        isTrue,
        reason: 'BUG-2331：$path 的退出必须走 exitAfterPersist，'
            '否则一次卡住的 drift 写就能让 iOS 用户永久困在页内。',
      );
    }
  });

  test('小说阅读器在内容就绪前也挂着返回键', () {
    final File reader =
        File('lib/src/pages/implementations/reader_fushi_page.dart');
    final String source = reader.readAsStringSync();
    // 顶栏（含返回箭头）的可见条件里有 `_hasEverLoaded`，它只在 WebView 首屏渲染
    // 成功后才置位；书打不开时整页只剩一个转圈。出口必须挂在**未就绪**这一侧。
    expect(
      source.contains('if (!_hasEverLoaded)'),
      isTrue,
      reason: 'BUG-2230/BUG-2331：内容未就绪时必须无条件渲染出口',
    );
    expect(
      source.contains("'reader_unloaded_back'"),
      isTrue,
      reason: 'BUG-2331：未就绪态的返回键（key: reader_unloaded_back）不见了。'
          'iOS 上没有系统返回键、canPop:false 关掉了侧滑、点空白唤顶栏又依赖'
          '尚不存在的页内 JS——它是坏书场景下唯一的出口。',
    );
  });
}
