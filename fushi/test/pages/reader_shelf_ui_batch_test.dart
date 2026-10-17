// 2026-10-09 阅读器 / 书架 / 模块设置一批改动的回归测试：
// * 书架标签段不再画「管理标签」大 chip（与工具行常驻齿轮重复）；
// * 阅读设置「主题与字体」页有「正文字体」入口（复用字体库）；
// * 有声书面板的播放设置并进「阅读设置 › 有声书」页；
// * 合集详情 hero 深色底降彩度、列表进度条完成色；
// * 歌词模式（有声阅读界面）窄屏左上角返回键。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_detail_hero.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart'
    show readerBodyFontSummary;
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';

Widget _host(Widget child) => ProviderScope(
  child: TranslationProvider(
    child: MaterialApp(home: Scaffold(body: child)),
  ),
);

List<BookTagRow> _tags() => <BookTagRow>[
  for (int i = 0; i < 3; i++)
    BookTagRow(
      id: i,
      name: '标签$i',
      colorValue: 0xFF2196F3,
      sortOrder: i,
      createdAt: 0,
    ),
];

String _code(String path) => maskCommentsAndStrings(
  File(path).readAsStringSync(),
);

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('标签段不再画「管理标签」大 chip，工具行齿轮仍是唯一入口', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FushiTagFilterBar(
          tags: _tags(),
          part: FushiTagFilterBarPart.tags,
          onToggleFilter: (_) {},
          onReorder: (_, __) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('标签0'), findsOneWidget);
    expect(find.text(t.tag_manage), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('library_tag_manage_chip')),
      findsNothing,
    );

    await tester.pumpWidget(
      _host(
        FushiTagFilterBar(
          tags: _tags(),
          part: FushiTagFilterBarPart.actions,
          onToggleFilter: (_) {},
          onReorder: (_, __) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('library_tag_settings')),
      findsOneWidget,
      reason: '工具行行尾的「管理标签」齿轮常驻，老用户的标签管理入口不丢',
    );
  });

  test('阅读设置「主题与字体」页首项是正文字体切换', () {
    final ReaderSettingsSectionSpec font = kReaderSettingsSections.firstWhere(
      (ReaderSettingsSectionSpec s) => s.id == 'font',
    );
    expect(font.tab, ReaderSettingsTab.appearance);
    expect(font.itemIds.first, 'reading_display.body_font');
    final String schema = _code(
      'lib/src/settings/settings_schema_reading.dart',
    );
    expect(
      containsIdentifierCall(schema, 'CustomFontsPage'),
      isTrue,
      reason: '复用全 app 唯一的字体库（导入 / 下载 / 用途勾选），不另写字体管理',
    );
  });

  test('正文字体副标题：按回退顺序列出字体名，空链显示默认', () {
    expect(
      readerBodyFontSummary(const <Map<String, dynamic>>[]),
      t.reader_body_font_default,
    );
    expect(
      readerBodyFontSummary(const <Map<String, dynamic>>[
        <String, dynamic>{'name': '霞鹜文楷', 'path': '/f/a.ttf'},
        <String, dynamic>{'name': ' ', 'path': '/f/b.ttf'},
        <String, dynamic>{'name': 'Noto Serif JP'},
      ]),
      '霞鹜文楷 › Noto Serif JP',
    );
  });

  test('有声书面板不再有「设置」页签，播放设置在阅读设置「有声书」页', () {
    final String panel = _code('lib/src/reader/reader_audiobook_panel.dart');
    expect(containsIdentifier(panel, 'settingsBuilder'), isFalse);
    expect(containsIdentifier(panel, 'ReaderPanelTabs'), isFalse);
    final String sheet = _code(
      'lib/src/media/audiobook/reader_quick_settings_sheet.dart',
    );
    expect(
      RegExp(
        r'if \(tab == ReaderSettingsTab\.listening\)\s*'
        r'_buildAudiobookSettingsSection\(',
      ).hasMatch(sheet),
      isTrue,
      reason: '音量 / 速度 / 延迟 / 播放条等行不能随页签一起丢',
    );
  });

  test('合集 hero 底色：深色降彩度，浅色维持原配比', () {
    for (final Brightness brightness in Brightness.values) {
      final ColorScheme scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6200EE),
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
      );
      final Color expected = Color.alphaBlend(
        scheme.primaryContainer.withValues(
          alpha: brightness == Brightness.dark ? 0.32 : 0.62,
        ),
        scheme.surfaceContainerLow,
      );
      expect(collectionHeroBackground(scheme), expected);
    }
  });

  test('合集列表行进度条：读完用完成色、平直形态，不再恒为 primary', () {
    final String page = _code(
      'lib/src/pages/implementations/media_collection_grid_detail_page.dart',
    );
    final int start = page.indexOf('class _MemberListRow');
    expect(start, isNonNegative);
    final String row = page.substring(start);
    expect(row.contains('ShelfReadStatus.finished'), isTrue);
    expect(row.contains('scheme.tertiary'), isTrue);
    expect(row.contains('year2023: apple ? null : true'), isTrue);
  });

  test('歌词模式（有声阅读界面）窄屏有左上角返回键，退出走 onClose', () {
    for (final String path in <String>[
      'lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart',
      'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      final int key = src.indexOf("ValueKey<String>('lyrics_player_back')");
      expect(key, isNonNegative, reason: '$path 缺返回键');
      final String around = src.substring(key, key + 400);
      expect(around.contains('t.back'), isTrue);
      expect(around.contains('callbacks.onClose'), isTrue);
    }
  });
}
