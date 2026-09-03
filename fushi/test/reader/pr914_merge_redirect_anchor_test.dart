import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PR#914 阻塞③：冷启动恢复重定向到「宿主正文章」时，必须把三个恢复锚一起归零。
///
/// `_loadChapterDirectly` 拿 `_initialProgress` / `_initialCharOffset` /
/// `_initialCharOffsetEnd` 三个字段建恢复脚本。`onLoadStop` 里的
/// TODO-1128 重定向原来只改 `_currentChapter`，锚原封不动 —— 于是宿主章会被按**旧章**
/// 的位置恢复。
///
/// 真实可达路径：合并关闭时用户往回翻到独立插图章 → `_handlePageTurnLimit` 走
/// `progress:0.99`；纯图片章 `totalChars==0` 让真实滚动值永远覆盖不掉它，退出落库
/// `normCharOffset=9900`。合并默认翻成 ON 后冷开该书 → 重定向到宿主正文章却保留
/// 0.99 → 整章正文被跳过。另两个重定向点（`navigation.part.dart` 的
/// `_navigateToChapter`、`chrome.part.dart` 的 `reloadWithCurrentSettings`）本来就归零，
/// 这条是唯一的漏网点。
///
/// 断言用到的生产代码字面量（改名要同步改这里）：
///   '_resolveNavChapter(_currentChapter)' —— 重定向判据
///   '_initialProgress = 0.0'
///   '_initialCharOffset = -1'
///   '_initialCharOffsetEnd = -1'
void main() {
  test('onLoadStop 的宿主章重定向归零三个恢复锚（PR#914 ③）', () {
    final String source = _readSource(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart');
    final String block = _slice(
      source,
      'final int hostChapter = _resolveNavChapter(_currentChapter);',
      '_loadChapterDirectly(_currentChapter);',
    );

    expect(block, contains('_currentChapter = hostChapter;'),
        reason: '前提：这就是那个重定向点');
    expect(block, contains('_initialProgress = 0.0;'),
        reason: '保留旧章 progress（可能是 0.99）= 冷开被甩到宿主章章末（PR#914 ③）');
    expect(block, contains('_initialCharOffset = -1;'),
        reason: '旧章的绝对字符锚对宿主章没有意义，必须归零');
    expect(block, contains('_initialCharOffsetEnd = -1;'),
        reason: '句尾锚同理，否则泄漏进宿主章的恢复脚本');
  });

  test('另两个重定向点仍保持同一归零口径（防单点漂移）', () {
    final String nav = _readSource(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart');
    final String navBlock = _slice(
      nav,
      'final int resolvedChapter = _resolveNavChapter(index);',
      'if (!manual && _book!.isChapterNav(index))',
    );
    expect(navBlock, contains('progress = 0.0;'));
    expect(navBlock, contains('charOffset = null;'));
    expect(navBlock, contains('charOffsetEnd = -1;'));

    final String chrome = _readSource(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart');
    final String chromeBlock = _slice(
      chrome,
      'final int hostChapter = _resolveNavChapter(_currentChapter);',
      'if (_lyricsMode) {',
    );
    expect(chromeBlock, contains('_lastProgressValue = 0.0;'));
    expect(chromeBlock, contains('_lastProgressCharOffset = -1;'));
  });
}

String _readSource(String relativePath) {
  final File file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: '源文件不存在：$relativePath');
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// 切出 [start] 到 [end] 之间的片段。两个标记都必须存在，否则守卫会静默扫空区间。
String _slice(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: '缺起始标记：$start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: '缺结束标记：$end');
  return source.substring(startIndex, endIndex);
}
