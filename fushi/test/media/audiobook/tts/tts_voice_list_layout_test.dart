import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_two_pane_layout.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_list_layout.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:material_ui/material_ui.dart';

/// 「朗读声音」版面：宽屏双栏（声音侧栏 + 右侧详情）、窄屏列表 → 推详情；
/// 行首单选一键设为使用中、行尾删除（先确认）；全程可用 Tab + Enter 操作。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  const List<TtsVoiceListEntry> voices = <TtsVoiceListEntry>[
    TtsVoiceListEntry(
      id: 'a',
      title: 'Voice A',
      subtitle: 'Online service · Microsoft Edge',
      icon: Icons.cloud,
    ),
    TtsVoiceListEntry(
      id: 'b',
      title: 'Voice B',
      subtitle: 'External service · GPT-SoVITS',
      icon: Icons.devices,
      incomplete: true,
    ),
  ];

  /// 调用记录：`select:x` / `open:x` / `use:x` / `delete:x` / `add:wide|narrow`。
  Future<List<String>> pumpLayout(
    WidgetTester tester,
    Size size, {
    String? activeId = 'a',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<String> calls = <String>[];
    List<TtsVoiceListEntry> list = voices;
    String? active = activeId;
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                TtsVoiceListLayout(
                  voices: list,
                  activeId: active,
                  selectedId: selected,
                  onSelect: (String id) {
                    calls.add('select:$id');
                    setState(() => selected = id);
                  },
                  onOpen: (String id) => calls.add('open:$id'),
                  onUse: (String id) {
                    calls.add('use:$id');
                    setState(() => active = id);
                  },
                  onDelete: (String id) {
                    calls.add('delete:$id');
                    setState(() {
                      list = <TtsVoiceListEntry>[
                        for (final TtsVoiceListEntry v in list)
                          if (v.id != id) v,
                      ];
                      if (active == id) {
                        active = list.isEmpty ? null : list.first.id;
                      }
                    });
                  },
                  onAdd: (bool wide) =>
                      calls.add('add:${wide ? 'wide' : 'narrow'}'),
                  detailBuilder: (BuildContext context, String id) =>
                      ListView(children: <Widget>[Text('detail $id')]),
                  cacheSubtitle: 'Synthesized audio: 3 MB',
                  onClearCache: () => calls.add('clear'),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  /// 主焦点是否落在 [finder] 那个 widget 之内（含它自己）。
  bool focusWithin(WidgetTester tester, Finder finder) {
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final Element target = tester.element(finder);
    if (focused == target) return true;
    bool found = false;
    (focused as Element).visitAncestorElements((Element e) {
      if (e == target) found = true;
      return !found;
    });
    return found;
  }

  /// 连按 Tab 直到焦点进入 [finder]（防死循环：最多 30 次）。
  Future<void> tabTo(WidgetTester tester, Finder finder) async {
    for (int i = 0; i < 30; i++) {
      if (focusWithin(tester, finder)) return;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    fail('Tab never reached $finder');
  }

  Finder key(String value) => find.byKey(ValueKey<String>(value));

  test('selection falls back to the active voice, then the first one', () {
    expect(
      resolveTtsVoiceSelection(voices, selectedId: 'b', activeId: 'a'),
      'b',
    );
    expect(
      resolveTtsVoiceSelection(voices, selectedId: 'gone', activeId: 'b'),
      'b',
    );
    expect(
      resolveTtsVoiceSelection(voices, selectedId: null, activeId: null),
      'a',
    );
    expect(
      resolveTtsVoiceSelection(
        const <TtsVoiceListEntry>[],
        selectedId: 'a',
        activeId: 'a',
      ),
      isNull,
    );
  });

  testWidgets('1280x800: voice sidebar + detail pane, select shows detail', (
    WidgetTester tester,
  ) async {
    final List<String> calls = await pumpLayout(tester, const Size(1280, 800));
    expect(key('tts-voice-layout-wide'), findsOne);
    expect(key('tts-voice-settings'), findsNothing);

    final Finder sidebar = key('tts-voice-sidebar');
    expect(tester.getSize(sidebar).width, kTtsSidebarWidth);
    for (final String id in <String>['a', 'b']) {
      expect(
        find.descendant(of: sidebar, matching: key('tts-voice-$id')),
        findsOne,
      );
    }
    expect(
      find.descendant(of: sidebar, matching: key('tts-voice-add')),
      findsOne,
    );
    expect(
      find.descendant(of: sidebar, matching: key('tts-voice-cache-clear')),
      findsOne,
    );
    // 没选过：右侧显示使用中的声音，且在侧栏右边。
    expect(find.text('detail a'), findsOne);
    expect(
      tester.getTopLeft(find.text('detail a')).dx,
      greaterThanOrEqualTo(tester.getTopRight(sidebar).dx),
    );
    // 未完成的声音在说明行带警示。
    expect(
      find.textContaining(t.audiobook_tts_voice_incomplete_status),
      findsOne,
    );

    // 焦点导航：Tab 到 B 行、Enter = 在右侧显示（不推页、不改使用中）。
    await tabTo(tester, key('tts-voice-b'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, <String>['select:b']);
    expect(find.text('detail b'), findsOne);
    expect(find.text('detail a'), findsNothing);

    // 添加声音：双栏下回调带 wide = true（页面据此不推页）。
    await tester.tap(key('tts-voice-add'));
    await tester.pumpAndSettle();
    expect(calls.last, 'add:wide');
  });

  testWidgets('400x800: plain list, tapping a row opens the editor page', (
    WidgetTester tester,
  ) async {
    final List<String> calls = await pumpLayout(tester, const Size(400, 800));
    expect(key('tts-voice-settings'), findsOne);
    expect(key('tts-voice-layout-wide'), findsNothing);
    expect(key('tts-voice-sidebar'), findsNothing);
    expect(find.textContaining('detail'), findsNothing);

    await tester.tap(find.text('Voice B'));
    await tester.pumpAndSettle();
    expect(calls, <String>['open:b']);

    await tester.tap(key('tts-voice-add'));
    await tester.pumpAndSettle();
    expect(calls.last, 'add:narrow');
  });

  for (final Size size in const <Size>[Size(1280, 800), Size(400, 800)]) {
    testWidgets('${size.width.toInt()}w: radio sets the voice in use '
        'via Tab + Enter', (WidgetTester tester) async {
      final List<String> calls = await pumpLayout(tester, size);
      final Finder radioB = key('tts-voice-use-b');
      await tabTo(tester, radioB);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, <String>['use:b']);
      expect(
        tester.widget<FushiRadio<String>>(radioB).groupValue,
        'b',
        reason: 'B is now the voice in use',
      );
      // 已在使用中的再点一次不重复回调。
      await tester.tap(radioB);
      await tester.pumpAndSettle();
      expect(calls, <String>['use:b']);
    });

    testWidgets('${size.width.toInt()}w: delete asks first, cancel keeps it, '
        'confirm deletes', (WidgetTester tester) async {
      final List<String> calls = await pumpLayout(tester, size);
      final Finder deleteA = key('tts-voice-delete-a');

      // 取消：Esc 关掉确认框，什么都不删。
      await tabTo(tester, deleteA);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(t.audiobook_tts_voice_delete), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(key('tts-voice-a'), findsOne);

      // 确认：确认键默认聚焦，Enter 即删；删的是使用中的声音时由宿主切换。
      await tester.tap(deleteA);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, <String>['delete:a']);
      expect(key('tts-voice-a'), findsNothing);
      expect(
        tester.widget<FushiRadio<String>>(key('tts-voice-use-b')).groupValue,
        'b',
      );
    });
  }
}
