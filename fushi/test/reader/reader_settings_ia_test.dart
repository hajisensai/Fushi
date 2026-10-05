import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';

/// 2026-10 阅读设置侧板重设计：标签页集合 / 初始页 / 小节表的纯函数守卫。
void main() {
  group('readerSettingsTabs', () {
    test('书籍模式：主题与字体 → 排版 → 翻页与手势 → 有声书 → 查词 → 歌词模式', () {
      expect(
        readerSettingsTabs(
          lyricsMode: false,
          listeningEnabled: true,
          lyricsAvailable: true,
        ),
        <ReaderSettingsTab>[
          ReaderSettingsTab.appearance,
          ReaderSettingsTab.layout,
          ReaderSettingsTab.gestures,
          ReaderSettingsTab.listening,
          ReaderSettingsTab.lookup,
          ReaderSettingsTab.lyrics,
        ],
      );
    });

    test('没有有声书时不出歌词页；听书模块关掉时不出有声书页', () {
      expect(
        readerSettingsTabs(lyricsMode: false, listeningEnabled: false),
        <ReaderSettingsTab>[
          ReaderSettingsTab.appearance,
          ReaderSettingsTab.layout,
          ReaderSettingsTab.gestures,
          ReaderSettingsTab.lookup,
        ],
      );
    });

    test('歌词模式：歌词页置首、排版页隐藏', () {
      final List<ReaderSettingsTab> tabs = readerSettingsTabs(
        lyricsMode: true,
        listeningEnabled: true,
      );
      expect(tabs.first, ReaderSettingsTab.lyrics);
      expect(tabs, isNot(contains(ReaderSettingsTab.layout)));
      expect(
        tabs.where((ReaderSettingsTab t) => t == ReaderSettingsTab.lyrics),
        hasLength(1),
      );
    });
  });

  group('readerSettingsInitialTab', () {
    final List<ReaderSettingsTab> book = readerSettingsTabs(
      lyricsMode: false,
      listeningEnabled: true,
      lyricsAvailable: true,
    );
    final List<ReaderSettingsTab> lyrics = readerSettingsTabs(
      lyricsMode: true,
      listeningEnabled: true,
    );

    test('记忆的页存在就用它（旧 id behavior 映射到翻页与手势）', () {
      expect(
        readerSettingsInitialTab(book, remembered: 'behavior', lyricsMode: false),
        ReaderSettingsTab.gestures,
      );
      expect(
        readerSettingsInitialTab(book, remembered: 'lookup', lyricsMode: false),
        ReaderSettingsTab.lookup,
      );
    });

    test('歌词模式里记忆的是书籍模式专属页时落歌词页', () {
      expect(
        readerSettingsInitialTab(lyrics, remembered: 'layout', lyricsMode: true),
        ReaderSettingsTab.lyrics,
      );
    });

    test('未知 id 落第一页', () {
      expect(
        readerSettingsInitialTab(book, remembered: 'nope', lyricsMode: false),
        ReaderSettingsTab.appearance,
      );
    });
  });

  group('kReaderSettingsSections', () {
    test('小节 id 唯一；高级 / 视觉小说 / 按钮布局 / 翻页方向默认折叠', () {
      final List<String> ids = <String>[
        for (final ReaderSettingsSectionSpec s in kReaderSettingsSections) s.id,
      ];
      expect(ids.toSet(), hasLength(ids.length));
      final Set<String> collapsed = <String>{
        for (final ReaderSettingsSectionSpec s in kReaderSettingsSections)
          if (s.collapsed) s.id,
      };
      expect(
        collapsed,
        containsAll(<String>[
          'layout_vn',
          'layout_advanced',
          'gestures_direction',
          'gestures_buttons',
          'lookup_advanced',
        ]),
      );
      // 常用小节不折叠。
      expect(collapsed, isNot(contains('layout_common')));
      expect(collapsed, isNot(contains('gestures_common')));
      expect(collapsed, isNot(contains('font')));
    });

    test('一个 schema 项只归一个小节', () {
      final Map<String, String> owner = <String, String>{};
      for (final ReaderSettingsSectionSpec s in kReaderSettingsSections) {
        for (final String id in s.itemIds) {
          expect(owner.containsKey(id), isFalse,
              reason: '$id 同时登记在 ${owner[id]} 与 ${s.id}');
          owner[id] = s.id;
        }
      }
    });

    test('歌词模式页不收任何 schema 小节（全是歌词专属控件）', () {
      expect(
        kReaderSettingsSections.where(
          (ReaderSettingsSectionSpec s) => s.tab == ReaderSettingsTab.lyrics,
        ),
        isEmpty,
      );
    });
  });
}
