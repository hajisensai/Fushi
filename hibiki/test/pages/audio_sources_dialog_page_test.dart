import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/pages/implementations/dictionary_settings_dialog_page.dart';
import 'package:hibiki/utils.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: home)),
    );
  }

  // 把对话框 push 成真正的 route，这样行尾「关闭」按钮的 Navigator.pop 能正常
  // 出栈并触发 onSave（对话框直接当 MaterialApp.home 时 pop 根 route 会抛）。
  Future<void> openDialog(
    WidgetTester tester,
    AudioSourcesDialog dialog,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () =>
                    showDialog<void>(context: context, builder: (_) => dialog),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // 在 MaterialApp.builder 里注入 HibikiAppUiScale（与 main.dart 生产结构一致：
  // 缩放包住 Navigator/Overlay，对话框在缩放内），用于验证 BUG-027 的拖拽门控。
  Future<void> openDialogScaled(
    WidgetTester tester,
    AudioSourcesDialog dialog,
    double scale,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              HibikiAppUiScale(scale: scale, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () =>
                    showDialog<void>(context: context, builder: (_) => dialog),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  test('isValidRemoteUrl enforces http(s) + a term/reading placeholder', () {
    expect(AudioSourcesDialog.isValidRemoteUrl('https://x.com/{term}'), isTrue);
    expect(
        AudioSourcesDialog.isValidRemoteUrl('http://x.com/{reading}'), isTrue);
    // 无占位符
    expect(AudioSourcesDialog.isValidRemoteUrl('https://x.com/audio'), isFalse);
    // 非 http(s)
    expect(AudioSourcesDialog.isValidRemoteUrl('ftp://x.com/{term}'), isFalse);
    // 无 scheme / authority
    expect(AudioSourcesDialog.isValidRemoteUrl('{term}'), isFalse);
    expect(AudioSourcesDialog.isValidRemoteUrl(''), isFalse);
  });

  testWidgets('fits a compact desktop window with many remote sources', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: List<AudioSourceConfig>.generate(
            12,
            (int i) => AudioSourceConfig.remoteAudio(
              url: 'https://audio.example.com/$i/{term}/{reading}',
            ),
          ),
          onSave: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('rejects an invalid url and clears the error on a valid one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: const <AudioSourceConfig>[],
          onSave: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://x.com/{term}/{reading}',
    );
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsNothing);
  });

  testWidgets(
      'renders local audio rows inline with no master switch and exposes '
      'the add-db entry', (WidgetTester tester) async {
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.localAudio(
              label: 'android.db', path: '/a.db', enabled: true),
        ],
        onSave: (_) {},
        onPickLocalDb: (bool reference) async => null,
      ),
    );

    // 本地库行直接渲染在统一列表里（无需展开任何分组）。
    expect(find.text('android.db'), findsOneWidget);
    // 「添加本地音频数据库」入口始终可见（不再藏在折叠组里）。
    expect(find.text(t.local_audio_add_db), findsOneWidget);
    // 不再有「本地音频」master 组头 / 总开关。
    expect(find.text(t.local_audio), findsNothing);
  });

  testWidgets('adding a remote url inserts it at the top of the saved list',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://old.example.com/{term}'),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
      ),
    );

    await tester.enterText(
        find.byType(TextField), 'https://new.example.com/{term}');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.length, 2);
    expect(saved!.first.url, 'https://new.example.com/{term}');
  });

  testWidgets('adding a local db inserts it at the top of the saved list',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://old.example.com/{term}'),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
        onPickLocalDb: (bool reference) async => AudioSourceConfig.localAudio(
            label: 'new.db', path: '/new.db', enabled: true),
      ),
    );

    await tester.tap(find.text(t.local_audio_add_db));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.first.kind, AudioSourceKind.localAudio);
    expect(saved!.first.path, '/new.db');
  });

  // BUG-053：导入本地音频后，若用「点遮罩 / 系统返回 / Esc」关闭对话框（而非底部
  // 「关闭」按钮），过去 onSave 从不触发 → 导入丢失（且拷贝副本被 pruneOrphans 回收）。
  // 修复=任意关闭路径都落盘（save-on-dispose），故这里不点「关闭」按钮、改点遮罩关闭，
  // 仍必须持久化导入的本地库。
  testWidgets(
      'imported local db persists when the dialog is dismissed by the barrier '
      '(not the close button) (BUG-053)', (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: const <AudioSourceConfig>[],
        onSave: (List<AudioSourceConfig> v) => saved = v,
        onPickLocalDb: (bool reference) async => AudioSourceConfig.localAudio(
            label: 'new.db', path: '/new.db', enabled: true),
      ),
    );

    await tester.tap(find.text(t.local_audio_add_db));
    await tester.pumpAndSettle();

    // 不点「关闭」按钮，而是点对话框外的遮罩关闭（= 系统返回 / Esc 的等价关闭路径）。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 导入必须已落盘，而不是随对话框关闭一起丢失。
    expect(saved, isNotNull);
    expect(saved!.length, 1);
    expect(saved!.first.kind, AudioSourceKind.localAudio);
    expect(saved!.first.path, '/new.db');
  });

  // BUG-053（导入即落盘）：导入本地库时 onSave 当场触发，无需任何关闭动作——
  // 「导入成功」toast 名副其实，导入后即便直接杀进程也不丢。
  testWidgets(
      'imported local db persists immediately at import time, before any '
      'dialog close (BUG-053)', (WidgetTester tester) async {
    final List<List<AudioSourceConfig>> saves = <List<AudioSourceConfig>>[];
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: const <AudioSourceConfig>[],
        onSave: (List<AudioSourceConfig> v) =>
            saves.add(List<AudioSourceConfig>.of(v)),
        onPickLocalDb: (bool reference) async => AudioSourceConfig.localAudio(
            label: 'new.db', path: '/new.db', enabled: true),
      ),
    );

    await tester.tap(find.text(t.local_audio_add_db));
    await tester.pumpAndSettle();

    // 还没关闭对话框，导入就应已落盘（onSave 在导入时即被调用）。
    expect(saves, isNotEmpty);
    expect(saves.last.first.kind, AudioSourceKind.localAudio);
    expect(saves.last.first.path, '/new.db');
  });

  // BUG-027 ①：本地库行的「调整(tune)」按钮过去夹在 ↓ 和删除之间，把开关/↑/↓ 往左
  // 挤，导致跨行的开关列错位。修复后 tune 移到开关左侧——本地行与远端行的开关列右贴边
  // 对齐，tune 只向左凸出。
  testWidgets(
      'local-row switch aligns with remote rows and the tune button sits left '
      'of the switch (BUG-027)', (WidgetTester tester) async {
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.localAudio(
              label: 'android.db', path: '/a.db', enabled: true),
          AudioSourceConfig.remoteAudio(url: 'https://b.example.com/{term}'),
        ],
        onSave: (_) {},
        onEditLocalSources: (String _) async {},
      ),
    );

    final Finder switches = find.byType(Switch);
    expect(switches, findsNWidgets(2));
    final double localSwitchX = tester.getCenter(switches.at(0)).dx;
    final double remoteSwitchX = tester.getCenter(switches.at(1)).dx;
    // 开关列跨行对齐（本地行不再因 tune 被往左挤）。修复前 localSwitchX < remoteSwitchX。
    expect((localSwitchX - remoteSwitchX).abs(), lessThan(1.0));

    // tune（仅本地行）在开关左侧。修复前 tune 在 ↓ 与删除之间，dx > 开关。
    final double tuneX = tester.getCenter(find.byIcon(Icons.tune)).dx;
    expect(tuneX, lessThan(localSwitchX));
  });

  // BUG-027 ②：界面缩放（HibikiAppUiScale != 1.0）下，SDK ReorderableListView 的
  // Overlay 拖拽代理不认祖先 Transform.scale，长按拖拽会飞出屏幕。修复=改用自实现的
  // HibikiReorderableColumn（局部坐标拖拽），缩放下精确跟手、零偏移、视觉一致。
  testWidgets('uses HibikiReorderableColumn (not SDK ReorderableListView)',
      (WidgetTester tester) async {
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://a.example.com/{term}'),
          AudioSourceConfig.remoteAudio(url: 'https://b.example.com/{term}'),
        ],
        onSave: (_) {},
      ),
    );
    expect(find.byType(HibikiReorderableColumn), findsOneWidget);
    expect(find.byType(ReorderableListView), findsNothing);
  });

  testWidgets('long-press drag reorders rows even under 0.5 UI scale (BUG-027)',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    const String urlA = 'https://a.example.com/{term}';
    const String urlB = 'https://b.example.com/{term}';
    const String urlC = 'https://c.example.com/{term}';
    await openDialogScaled(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: urlA),
          AudioSourceConfig.remoteAudio(url: urlB),
          AudioSourceConfig.remoteAudio(url: urlC),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
      ),
      0.5,
    );

    // 抓 A 行标题（左侧文本、远离开关/按钮），长按下拖越过 B 行中点。
    // url 在标题与副标题各出现一次，取首个（标题）。
    final Offset start = tester.getCenter(find.text(urlA).first);
    final Offset next = tester.getCenter(find.text(urlB).first);
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(Offset.lerp(start, next, 0.6)!);
    await tester.pump();
    await gesture.moveTo(next);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.length, 3);
    // A 被拖到 B 之后（缩放下拖拽真实生效、未飞走）。
    final List<String?> order =
        saved!.map((AudioSourceConfig s) => s.url).toList();
    expect(order.indexOf(urlA), greaterThan(order.indexOf(urlB)));
  });
}
