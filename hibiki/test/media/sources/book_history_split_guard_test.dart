/// 守卫：三个书族媒体源必须保持 `implementsHistory: false`。
///
/// ## 守什么，为什么这条不变量比一次修复值钱
///
/// 「书 ↔ 漫画」转化（`book_format_rebuild.dart`）改的是 `EpubBooks.format`，
/// **不改** `bookKey`。书架、合集、标签、进度、统计、Profile 全都按 `bookKey` 关联，
/// 所以转化天然零悬挂引用、书架前后恰好一条。
///
/// 但 `MediaItem.uniqueKey` 不是 `mediaIdentifier`，而是
/// `'$mediaSourceIdentifier/$mediaIdentifier'`（`media_item.dart`），
/// 而 `mediaSourceIdentifier` 由 `ReaderFushiSource.mediaSourceKeyFor(format)`
/// **按当前 format 现算** —— 转化必然把它从 `reader_fushi` 换成 `reader_manga`
/// （或反过来）。`MediaItems.uniqueKey` 又是 UNIQUE 列。于是：
///
/// > 只要有任何一个书族源把 `implementsHistory` 置成 true，
/// > `AppModel.openMedia` 就会在开书时 `addMediaItem`，
/// > 同一本书转化前后会插进**两条** `media_items` 行，
/// > 最近打开流里一本书裂成两条。
///
/// 今天这件事**不会发生**：三个书族源全是 false，且全仓没有任何
/// `implementsHistory: true`（书架的「最近阅读」根本不走 `media_items`，
/// 它从 `ReaderPositions` 现算——见 `MediaSource.implementsHistory` 的文档）。
///
/// 所以这条守卫不是在修一个 bug，而是**用不变量替代修复机械**：与其等有人把它翻成
/// true、再写几百行去合并被劈成两半的历史，不如在这里钉死「别翻」。翻了这条测试
/// 立刻红，理由就写在断言的 reason 里，读到的人不需要重新推导一遍。
///
/// ## 变异实测打在哪
///
/// 把三个源里任意一个的 `implementsHistory: false` 改成 `true` ⇒ 第一条 test 必红。
/// 新增第四个 `ReaderMediaSource` 子类而不登记 ⇒ 第三条 test 必红。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/source_guard.dart';

void main() {
  test('三个书族源恒 implementsHistory:false（翻了就把一本书的历史劈成两条）', () {
    // 行为断言，不是语料断言：语料能被等价改写绕过，构造出来的实例不能。
    const String why = '书族源必须保持 implementsHistory:false。'
        'MediaItem.uniqueKey = 源标识 + "/" + 媒体标识，'
        '而源标识由 EpubBooks.format 现算——「书 ↔ 漫画」转化'
        '必然改它。置 true 会让 openMedia 在转化前后各插一条 media_items，'
        '同一本书在最近打开流里裂成两条，且 UNIQUE 列救不了（键本来就不同）。'
        '书的「最近阅读」现算自 ReaderPositions，从不需要 media_items。';
    expect(ReaderFushiSource.instance.implementsHistory, isFalse, reason: why);
    expect(ReaderPdfSource.instance.implementsHistory, isFalse, reason: why);
    expect(MangaFushiSource.instance.implementsHistory, isFalse, reason: why);
  });

  test('分裂机制是真的：同一本书三种 format 派生出三个互异的 MediaItem.uniqueKey', () {
    // 这条把上面那段理由从注释变成可执行的事实。它**恒真**（三个源键本就互异，
    // 见 manga_routing_guard_test），存在的意义是：谁想把上面那条 false 改成
    // true 之前，先在这里看见「改了会发生什么」。
    const String bookKey = 'Scanned Volume 01';
    final String mediaIdentifier =
        ReaderFushiSource.mediaIdentifierFor(bookKey);
    final Set<String> uniqueKeys = <String>{
      for (final BookFormat format in BookFormat.values)
        MediaItem(
          mediaIdentifier: mediaIdentifier,
          title: bookKey,
          mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
          mediaSourceIdentifier: ReaderFushiSource.mediaSourceKeyFor(format),
          position: 0,
          duration: 1,
          canDelete: false,
          canEdit: true,
        ).uniqueKey,
    };
    expect(uniqueKeys, hasLength(BookFormat.values.length),
        reason: 'mediaIdentifier 三种 format 完全相同（转化不改 bookKey），'
            'uniqueKey 却互异——差的正是 mediaSourceIdentifier。'
            '这就是 implementsHistory 一旦为 true 就会分裂历史的机制。');
    // 反面：身份本身没变，变的只有源标识。
    expect(mediaIdentifier, ReaderFushiSource.mediaIdentifierFor(bookKey),
        reason: 'mediaIdentifier 只由 bookKey 决定，与 format 无关——'
            '转化不改 bookKey ⇒ 它逐字节不变');
  });

  test('书族源就这三个——新增第四个必须来这里登记并守住 false', () {
    // 正向枚举：扫 lib/ 找出全部 ReaderMediaSource 子类，与上面断言过的三个比对。
    // 反过来「用已断言的集合去取反」会让新增的源天生落在集合外、零覆盖。
    final RegExp declaration =
        RegExp(r'class\s+(\w+)\s+extends\s+ReaderMediaSource');
    final Set<String> found = <String>{};
    for (final FileSystemEntity entity
        in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // 走共享掩码：注释里写「EPUB / 漫画 / PDF 都 extends ReaderMediaSource」这类
      // 说明是资产，不该被当成一个真的声明（`media_item_edit_dialog_page.dart`
      // 里就有一句）。掩码与原文等长，正则窗口语义不变。
      for (final RegExpMatch match
          in declaration.allMatches(maskComments(entity.readAsStringSync()))) {
        found.add(match.group(1)!);
      }
    }
    expect(
      found,
      <String>{'ReaderFushiSource', 'ReaderPdfSource', 'MangaFushiSource'},
      reason: '发现了未登记的书族媒体源：${found.toList()..sort()}。'
          '书族源共用同一个 EpubBooks 身份、且会被「书 ↔ 漫画」转化在它们之间'
          '切换，所以每一个都必须 implementsHistory:false 并在本文件第一条断言里'
          '登记。删了源也要来改这里。',
    );
    // 扫描本身失效（目录改名 / listSync 拿不到东西）必须红，不能静默变成摆设。
    expect(found, isNotEmpty, reason: '一个 ReaderMediaSource 子类都没扫到——扫描逻辑失效了');
  });
}
