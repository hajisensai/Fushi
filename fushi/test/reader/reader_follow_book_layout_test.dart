// 反馈 sYPkmtitOM「跟随原书」：ReaderSettings 的 writingMode / spreadDirection 是
// 全部消费点（正文 CSS、分页脚本、spread 页序、查词竖排判定）读的唯一生效值。
// 本测试锁：
//   * 默认开；开着时打开的书声明了的项取书本值，没声明的项回落用户设置；
//   * 关掉立即回落用户设置，持久化值始终是用户自己的（从不被书本改写）；
//   * 多个阅读器叠放时按登记顺序取最上层，关一本只撤自己的；
//   * 设置页的「来自本书」判定（置灰排版方向 / 页序）与生效值同源；
//   * 阅读器页在解析完书后登记、dispose 时撤销（源码守卫）。
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_original_layout.dart';

const BookOriginalLayout _verticalRtl = BookOriginalLayout(
  writingMode: 'vertical-rl',
  spreadDirection: 'rtl',
);
const BookOriginalLayout _horizontalLtr = BookOriginalLayout(
  writingMode: 'horizontal-tb',
  spreadDirection: 'ltr',
);

void main() {
  late FushiDatabase db;
  late ReaderSettings settings;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    MediaSource.setDatabase(db);
    settings = ReaderSettings(db);
    await settings.refreshFromDb();
    ReaderFushiSource.readerSettings = settings;
  });

  tearDown(() async {
    ReaderFushiSource.readerSettings = null;
    await db.close();
  });

  test('默认开启「跟随原书」', () {
    expect(settings.followBookLayout, isTrue);
    expect(ReaderSettings.defaultFollowBookLayout, isTrue);
    expect(ReaderFushiSource.instance.readerFollowBookLayout, isTrue);
  });

  test('没有打开的书：生效值就是用户设置', () async {
    await settings.setWritingMode('vertical-rl');
    await settings.setSpreadDirection('rtl');
    expect(settings.activeBookLayout, isNull);
    expect(settings.writingMode, 'vertical-rl');
    expect(settings.spreadDirection, 'rtl');
    expect(ReaderFushiSource.instance.readerWritingModeFromBook, isFalse);
    expect(ReaderFushiSource.instance.readerSpreadDirectionFromBook, isFalse);
  });

  test('打开横排书：生效值取书本，持久化的用户设置不变', () async {
    await settings.setWritingMode('vertical-rl');
    await settings.setSpreadDirection('rtl');
    final Object reader = Object();

    settings.enterBookLayout(reader, _horizontalLtr);

    expect(settings.writingMode, 'horizontal-tb');
    expect(settings.spreadDirection, 'ltr');
    expect(settings.storedWritingMode, 'vertical-rl');
    expect(settings.storedSpreadDirection, 'rtl');
    expect(ReaderFushiSource.instance.readerWritingMode, 'horizontal-tb');
    expect(ReaderFushiSource.instance.readerWritingModeFromBook, isTrue);
    expect(ReaderFushiSource.instance.readerSpreadDirectionFromBook, isTrue);
    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:reader_fushi:writing_mode'], 'vertical-rl');

    settings.leaveBookLayout(reader);
    expect(settings.writingMode, 'vertical-rl');
    expect(settings.spreadDirection, 'rtl');
  });

  test('书只声明了一项：没声明的那项回落用户设置', () async {
    await settings.setWritingMode('horizontal-tb');
    await settings.setSpreadDirection('ltr');
    final Object reader = Object();

    settings.enterBookLayout(
      reader,
      const BookOriginalLayout(spreadDirection: 'rtl'),
    );

    expect(settings.writingMode, 'horizontal-tb');
    expect(settings.spreadDirection, 'rtl');
    expect(ReaderFushiSource.instance.readerWritingModeFromBook, isFalse);
    expect(ReaderFushiSource.instance.readerSpreadDirectionFromBook, isTrue);
  });

  test('书什么都没声明：完全用用户设置', () async {
    await settings.setWritingMode('horizontal-tb');
    settings.enterBookLayout(Object(), BookOriginalLayout.none);
    expect(settings.writingMode, 'horizontal-tb');
    expect(ReaderFushiSource.instance.readerWritingModeFromBook, isFalse);
  });

  test('关掉「跟随原书」立即回落用户设置，再打开又跟随', () async {
    await settings.setWritingMode('vertical-rl');
    settings.enterBookLayout(Object(), _horizontalLtr);
    expect(settings.writingMode, 'horizontal-tb');

    await ReaderFushiSource.instance.setReaderFollowBookLayout(false);
    expect(settings.followBookLayout, isFalse);
    expect(settings.writingMode, 'vertical-rl');
    expect(settings.bookWritingModeOverride, isNull);
    expect(ReaderFushiSource.instance.readerWritingModeFromBook, isFalse);

    // 关掉的选择要持久化：新实例从 DB 读回仍是关。
    final ReaderSettings restored = ReaderSettings(db);
    await restored.refreshFromDb();
    expect(restored.followBookLayout, isFalse);

    await ReaderFushiSource.instance.setReaderFollowBookLayout(true);
    expect(settings.writingMode, 'horizontal-tb');
  });

  test('多个阅读器叠放：最上层生效，关上层后恢复下层的书本排版', () async {
    await settings.setWritingMode('vertical-rl');
    final Object lower = Object();
    final Object upper = Object();

    settings.enterBookLayout(lower, _horizontalLtr);
    settings.enterBookLayout(upper, _verticalRtl);
    expect(settings.writingMode, 'vertical-rl');
    expect(settings.spreadDirection, 'rtl');

    settings.leaveBookLayout(upper);
    expect(settings.writingMode, 'horizontal-tb');
    expect(settings.spreadDirection, 'ltr');

    // 撤一个从没登记过的 owner 不影响现有登记。
    settings.leaveBookLayout(Object());
    expect(settings.writingMode, 'horizontal-tb');

    settings.leaveBookLayout(lower);
    expect(settings.activeBookLayout, isNull);
    expect(settings.writingMode, 'vertical-rl');
  });

  test('同一阅读器重复登记：替换旧值并移到最上层', () {
    final Object a = Object();
    final Object b = Object();
    settings.enterBookLayout(a, _verticalRtl);
    settings.enterBookLayout(b, _verticalRtl);
    settings.enterBookLayout(a, _horizontalLtr);
    expect(settings.activeBookLayout, _horizontalLtr);
    settings.leaveBookLayout(a);
    expect(settings.activeBookLayout, _verticalRtl);
  });

  group('源码守卫：阅读器页登记 / 撤销书本排版', () {
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();

    test('解析完书后、spread map 初始化前登记', () {
      final int enter = page.indexOf(
        '_settings?.enterBookLayout(this, _book!.originalLayout);',
      );
      final int parsed = page.indexOf("_openTrace.mark('parsed');");
      final int spread = page.indexOf('_initSpreadMap(');
      expect(enter, greaterThan(0), reason: '阅读器必须登记本书的原书排版');
      expect(enter, greaterThan(parsed), reason: '要等 _book 解析完');
      expect(
        enter,
        lessThan(spread),
        reason: 'spread map 读 spreadDirection，必须在它之前登记',
      );
    });

    test('登记前先确认页面仍挂载（解析期间关掉阅读器不能留下死登记）', () {
      final int enter = page.indexOf(
        '_settings?.enterBookLayout(this, _book!.originalLayout);',
      );
      final int parsed = page.indexOf("_openTrace.mark('parsed');");
      final String between = page.substring(parsed, enter);
      expect(
        between,
        contains('if (!mounted) return;'),
        reason: 'dispose 已先跑过 leaveBookLayout，卸载后再登记会永久劫持生效值',
      );
    });

    test('dispose 时撤销自己的登记', () {
      expect(page, contains('_settings?.leaveBookLayout(this);'));
    });
  });
}
