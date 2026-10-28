// 制卡设置：挖词目标 = Fushi 复习时，只作用于 Anki 发送链路的项（AnkiConnect、Anki
// 牌组 / 笔记类型、Lapis、批量制卡、跨设备中转、查重范围……）不显示也搜不到，
// 换成 Fushi 复习的牌组 / 笔记类型；目标切回 Anki 时一切照旧。切换即时生效。
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/models/module_id.dart';

import '../helpers/test_platform_services.dart';

class _TargetAppModel extends AppModel {
  _TargetAppModel({this.srsModuleOn = true}) : super(testPlatformServices());

  final bool srsModuleOn;
  SrsMiningTarget _target = SrsMiningTarget.anki;

  @override
  ModuleVisibility get moduleVisibility =>
      ModuleVisibility(<ModuleId>{if (srsModuleOn) ModuleId.srs});

  @override
  SrsMiningTarget get srsMiningTarget => _target;

  void switchTo(SrsMiningTarget target) {
    _target = target;
    notifyListeners();
  }
}

/// 只作用于 Anki 的正文条目（目标 = Fushi 复习时必须不可见）。
const List<String> _ankiOnlyEntries = <String>[
  'card_creation.anki.profile',
  'card_creation.anki.fetch',
  'card_creation.anki.create_lapis',
  'card_creation.anki.batch_mining',
  'card_creation.anki.queue_undelivered_mines',
  'card_creation.anki.pending_mine_landing',
  'card_creation.anki.pending_mines',
  'card_creation.anki.deck',
  'card_creation.anki.note_type',
  'card_creation.anki.duplicate_scope',
  'card_creation.anki.backup_import',
];

/// 只作用于 Anki 的子页入口（目标 = Fushi 复习时必须不可见）。
const List<String> _ankiOnlyNavItems = <String>[
  'card_creation.connection.open',
  'card_creation.fields.open',
  'card_creation.lapis.open',
  'card_creation.maintenance.open',
];

/// 不依赖 Anki 连接状态、在 Anki 目标下恒可见的条目（判 Anki 侧「照旧」）。
const List<String> _ankiUnconditional = <String>[
  'card_creation.anki.profile',
  'card_creation.anki.fetch',
  'card_creation.anki.create_lapis',
  'card_creation.anki.batch_mining',
  'card_creation.anki.queue_undelivered_mines',
  'card_creation.anki.pending_mine_landing',
  'card_creation.anki.pending_mines',
];

/// SRS 制卡同样复用的卡片内容类设置：两种目标下都可见。
const List<String> _sharedEntries = <String>[
  'card_creation.anki.tags',
  'card_creation.anki.tag_include_hibiki',
  'card_creation.anki.tag_include_category',
  'card_creation.anki.tag_book_name',
];

const List<String> _srsEntries = <String>[
  'card_creation.srs.deck',
  'card_creation.srs.note_type',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsDestination dest;
  setUpAll(() => dest = buildCardCreationDestination());

  SettingsBodySearchEntry entry(String id) => dest.bodySearchEntries
      .singleWhere((SettingsBodySearchEntry e) => e.id == id);

  bool navVisible(SettingsContext c, String id) {
    for (final SettingsSection s in dest.sections) {
      for (final SettingsItem i in s.items) {
        if (i.id == id) return s.isVisible(c) && i.isVisible(c);
      }
    }
    throw StateError('no nav item $id');
  }

  testWidgets('目标 = Fushi 复习时 Anki 专属项隐藏，切回 Anki 即时恢复', (
    WidgetTester tester,
  ) async {
    final _TargetAppModel app = _TargetAppModel();
    late SettingsContext ctx;
    int builds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            builds++;
            // 与 BasePage.appModel 一样 watch appProvider：目标一改宿主就重建。
            ref.watch(appProvider);
            ctx = SettingsContext(
              context: context,
              appModel: app,
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            return const SizedBox();
          },
        ),
      ),
    );

    // Anki 目标：Anki 侧照旧，SRS 两行不出现。
    for (final String id in _ankiUnconditional) {
      expect(entry(id).isVisible(ctx), isTrue, reason: id);
    }
    expect(navVisible(ctx, 'card_creation.connection.open'), isTrue);
    for (final String id in _srsEntries) {
      expect(entry(id).isVisible(ctx), isFalse, reason: id);
    }
    for (final String id in _sharedEntries) {
      expect(entry(id).isVisible(ctx), isTrue, reason: id);
    }

    // 切到 Fushi 复习：宿主即时重建，Anki 专属项全部隐藏。
    final int before = builds;
    app.switchTo(SrsMiningTarget.srs);
    await tester.pump();
    expect(builds, greaterThan(before), reason: '目标切换后设置页要即时刷新');
    for (final String id in _ankiOnlyEntries) {
      expect(entry(id).isVisible(ctx), isFalse, reason: id);
    }
    for (final String id in _ankiOnlyNavItems) {
      expect(navVisible(ctx, id), isFalse, reason: id);
    }
    for (final String id in <String>[
      ..._srsEntries,
      ..._sharedEntries,
      'card_creation.anki.srs_mining_target',
      // SRS 制卡同样读它们；不再要求 Anki 已连上。
      'card_creation.anki.allow_duplicates',
      'card_creation.anki.compact_glossaries',
      'card_creation.anki.overwrite_scope',
      // 新卡按词频重排：复习层自己读写新卡位置，挪进「Fushi 复习」分组。
      'card_creation.anki.reposition',
    ]) {
      expect(entry(id).isVisible(ctx), isTrue, reason: id);
    }
    // 复习没有「制卡后自动重排」：出卡直接按卡上的词频名次排（牌组「新卡顺序」）。
    expect(entry('card_creation.anki.reposition_auto').isVisible(ctx), isFalse);
    expect(navVisible(ctx, 'card_creation.media.open'), isTrue);

    // 切回 Anki：恢复。
    app.switchTo(SrsMiningTarget.anki);
    await tester.pump();
    for (final String id in _ankiUnconditional) {
      expect(entry(id).isVisible(ctx), isTrue, reason: id);
    }
    expect(navVisible(ctx, 'card_creation.connection.open'), isTrue);
    for (final String id in _srsEntries) {
      expect(entry(id).isVisible(ctx), isFalse, reason: id);
    }
  });

  testWidgets('复习模块关着：目标偏好即使是 Fushi 复习也不影响 Anki 项', (
    WidgetTester tester,
  ) async {
    final _TargetAppModel app = _TargetAppModel(srsModuleOn: false)
      ..switchTo(SrsMiningTarget.srs);
    late SettingsContext ctx;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            ctx = SettingsContext(
              context: context,
              appModel: app,
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            return const SizedBox();
          },
        ),
      ),
    );
    for (final String id in _ankiUnconditional) {
      expect(entry(id).isVisible(ctx), isTrue, reason: id);
    }
    for (final String id in _srsEntries) {
      expect(entry(id).isVisible(ctx), isFalse, reason: id);
    }
  });
}
