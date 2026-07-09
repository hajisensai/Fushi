// BUG-666 / TODO-1362：导入书对话框先选书 A（魔眼）又重选书 B（尸人）替换时，
// 下方标题框的书名不刷新。根因是五个书名回填点全部以 `if (_titleCtrl.text.isEmpty)`
// 为闸门——首次自动派生书名后标题非空，任何再选（含同一「选书」槽位换另一本）都被挡下。
//
// 修复引入标题来源身份 [ImportTitleSource] 与纯函数 [resolveImportTitle]：同来源重选
// 或标题为空才刷新，跨来源保持既有「非空即不覆盖」语义，用户手打的标题永不被覆盖。
//
// FilePicker 无法在 widget test 驱动、桌面拖放平台相关，故最强可落地层是纯函数单测
// + 源码守卫（同本仓 book_import_srtbook_pairing_test 的既有惯例）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';

void main() {
  group('resolveImportTitle — 同来源重选刷新（BUG-666 核心）', () {
    test('epub 先选 A 再重选 B → 书名刷新为 B', () {
      final r = resolveImportTitle(
        currentText: '魔眼',
        currentSource: ImportTitleSource.epub,
        incoming: ImportTitleSource.epub,
        derived: '尸人',
      );
      expect(r.text, '尸人');
      expect(r.source, ImportTitleSource.epub);
    });

    test('标题为空时任何来源都回填', () {
      final r = resolveImportTitle(
        currentText: '',
        currentSource: ImportTitleSource.none,
        incoming: ImportTitleSource.epub,
        derived: '尸人',
      );
      expect(r.text, '尸人');
      expect(r.source, ImportTitleSource.epub);
    });

    test('字幕重选 → 刷新为新字幕名', () {
      final r = resolveImportTitle(
        currentText: 'sub01',
        currentSource: ImportTitleSource.subtitle,
        incoming: ImportTitleSource.subtitle,
        derived: 'sub02',
      );
      expect(r.text, 'sub02');
      expect(r.source, ImportTitleSource.subtitle);
    });

    test('音频标签重选 → 刷新为新标签标题', () {
      final r = resolveImportTitle(
        currentText: '旧标签标题',
        currentSource: ImportTitleSource.metadata,
        incoming: ImportTitleSource.metadata,
        derived: '新标签标题',
      );
      expect(r.text, '新标签标题');
      expect(r.source, ImportTitleSource.metadata);
    });
  });

  group('resolveImportTitle — 用户手打保留 / 清空重填', () {
    test('用户手打后重选文件 → 保留用户输入，不覆盖', () {
      final r = resolveImportTitle(
        currentText: '我的自定义书名',
        currentSource: ImportTitleSource.user,
        incoming: ImportTitleSource.epub,
        derived: '尸人',
      );
      expect(r.text, '我的自定义书名');
      expect(r.source, ImportTitleSource.user);
    });

    test('用户清空标题后重选文件 → 空标题被新书名重填', () {
      final r = resolveImportTitle(
        currentText: '',
        currentSource: ImportTitleSource.user,
        incoming: ImportTitleSource.epub,
        derived: '尸人',
      );
      expect(r.text, '尸人');
      expect(r.source, ImportTitleSource.epub);
    });
  });

  group('resolveImportTitle — 跨来源不夺书名（零回归，与旧「非空即不覆盖」等价）', () {
    test('已有 epub 书名时再选字幕 → 保持 epub 书名', () {
      final r = resolveImportTitle(
        currentText: '尸人',
        currentSource: ImportTitleSource.epub,
        incoming: ImportTitleSource.subtitle,
        derived: 'chapter01',
      );
      expect(r.text, '尸人');
      expect(r.source, ImportTitleSource.epub);
    });

    test('已有 epub 书名时读到音频标签 → 保持 epub 书名（不被标签覆盖）', () {
      final r = resolveImportTitle(
        currentText: '海辺のカフカ_epub',
        currentSource: ImportTitleSource.epub,
        incoming: ImportTitleSource.metadata,
        derived: '海辺のカフカ',
      );
      expect(r.text, '海辺のカフカ_epub');
      expect(r.source, ImportTitleSource.epub);
    });

    test('已有字幕书名时再选 epub → 保持字幕书名（跨来源非空不覆盖）', () {
      final r = resolveImportTitle(
        currentText: 'sub01',
        currentSource: ImportTitleSource.subtitle,
        incoming: ImportTitleSource.epub,
        derived: 'book',
      );
      expect(r.text, 'sub01');
      expect(r.source, ImportTitleSource.subtitle);
    });

    test('已有音频标签书名时再选 epub → 保持标签书名（海辺のカフカ 存活）', () {
      final r = resolveImportTitle(
        currentText: '海辺のカフカ',
        currentSource: ImportTitleSource.metadata,
        incoming: ImportTitleSource.epub,
        derived: 'kafka_on_the_shore_jp',
      );
      expect(r.text, '海辺のカフカ');
      expect(r.source, ImportTitleSource.metadata);
    });
  });

  group('源码守卫：五个回填点必须统一走 _autoFillTitle，无残留 isEmpty 闸门', () {
    final String source =
        File('lib/src/media/audiobook/book_import_dialog.dart')
            .readAsStringSync();

    test('标题回填不再用 `_titleCtrl.text.isEmpty` 闸门（那是本 bug 的根因）', () {
      expect(source.contains('_titleCtrl.text.isEmpty'), isFalse,
          reason: '任何以标题为空判断是否回填的闸门都会复发 BUG-666，'
              '必须改走 _autoFillTitle + 来源身份。');
    });

    test('标题框 onChanged 把来源锁定为 user（保护用户手打）', () {
      expect(source.contains('_titleSource = ImportTitleSource.user'), isTrue,
          reason: '缺少 onChanged→user，用户手打的标题会被后续自动派生覆盖。');
    });

    test('五个回填点 + 方法定义共计至少 6 处 _autoFillTitle', () {
      final int occurrences = '_autoFillTitle('.allMatches(source).length;
      expect(occurrences, greaterThanOrEqualTo(6),
          reason: 'initState / 拖放 / 选书 / 选字幕 / 音频标签五点加方法定义，'
              '任一回填点绕过 _autoFillTitle 都会重现书名不刷新。');
    });
  });
}
