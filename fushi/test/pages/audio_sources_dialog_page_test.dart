import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/pages/implementations/dictionary_settings_dialog_page.dart';
import 'package:fushi/utils.dart';

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

  // 在 MaterialApp.builder 里注入 FushiAppUiScale（与 main.dart 生产结构一致：
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
              FushiAppUiScale(scale: scale, child: child!),
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

  // BUG-027 ②：界面缩放（FushiAppUiScale != 1.0）下，SDK ReorderableListView 的
  // Overlay 拖拽代理不认祖先 Transform.scale，长按拖拽会飞出屏幕。修复=改用自实现的
  // FushiReorderableColumn（局部坐标拖拽），缩放下精确跟手、零偏移、视觉一致。
  testWidgets('uses FushiReorderableColumn (not SDK ReorderableListView)',
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
    expect(find.byType(FushiReorderableColumn), findsOneWidget);
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
  // 远端 URL 过去只能删了重加（行尾只有开关/↑/↓/删除），写错一个字符就得整条重敲。
  // 修复=远端行给 ✎，把该行 URL 载入下方输入框改写，✓ 提交后落到**同一行**且保留
  // label / enabled / 位置。
  testWidgets(
      'editing a remote row rewrites that row in place, keeping its '
      'label, enabled state and position', (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://keep.example.com/{term}'),
          AudioSourceConfig.remoteAudio(
            url: 'http://localhost:5050/?term={term}',
            label: 'Anki',
            enabled: false,
          ),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
      ),
    );

    // 第 2 行（label=Anki、已关闭）的 ✎。
    expect(find.byIcon(Icons.edit_outlined), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.edit_outlined).at(1));
    await tester.pumpAndSettle();

    // 进入编辑态：原 URL 已载入输入框，+ 变 ✓，并出现取消 ✕。
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'http://localhost:5050/?term={term}',
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.enterText(
        find.byType(TextField), 'http://192.168.1.9:5050/?term={term}');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    // 提交后退出编辑态（✓ 变回 +，输入框清空）。
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);

    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    // 没有变成「删一条加一条」：仍是 2 条，且改的是原位那条。
    expect(saved!.length, 2);
    expect(saved![0].url, 'https://keep.example.com/{term}');
    expect(saved![1].url, 'http://192.168.1.9:5050/?term={term}');
    // 用户改的只是链接：显示名与启用状态不该被顺手重置。
    expect(saved![1].label, 'Anki');
    expect(saved![1].enabled, isFalse);
  });

  testWidgets('cancelling an edit leaves the source untouched',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://a.example.com/{term}'),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
      ),
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'https://typo.example.com/{term}');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // 取消后回到新增态，且不多出一条。
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved!.length, 1);
    expect(saved!.single.url, 'https://a.example.com/{term}');
  });

  // 编辑目标按值身份而非下标追踪：编辑期间把该行拖到别处（这里用等价的 ↓ 按钮重排），
  // 提交仍必须改到**它自己**，而不是原下标上现在那一行。
  testWidgets(
      'reordering while editing still writes to the edited row, not '
      'whatever now sits at its old index', (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(
              url: 'https://first.example.com/{term}'),
          AudioSourceConfig.remoteAudio(
              url: 'https://other.example.com/{term}'),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
      ),
    );

    // 编辑第 1 行，然后把它用 ↓ 移到第 2 位（编辑态保持）。
    await tester.tap(find.byIcon(Icons.edit_outlined).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down).at(0));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField), 'https://fixed.example.com/{term}');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved!.length, 2);
    // 被编辑的那条现在在第 2 位，改写落在它身上；未参与编辑的那条原文不动。
    expect(saved![0].url, 'https://other.example.com/{term}');
    expect(saved![1].url, 'https://fixed.example.com/{term}');
  });

  // 编辑中把该行删掉：提交不得把它当新增复活（那等于撤销用户的删除）。
  testWidgets('deleting the row being edited does not resurrect it on submit',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://gone.example.com/{term}'),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
      ),
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // 删除即退出编辑态（输入框清空、回到新增态的 +）。
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );

    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(saved, isEmpty);
  });

  // fushiRemote 无 URL 可改、本地库路径由文件选择器决定 → 都不给 ✎（只有自定义远端行有）。
  testWidgets('only remoteAudio rows expose the edit button',
      (WidgetTester tester) async {
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.fushiRemote(),
          AudioSourceConfig.localAudio(
              label: 'a.db', path: '/a.db', enabled: true),
          AudioSourceConfig.remoteAudio(url: 'https://a.example.com/{term}'),
        ],
        onSave: (_) {},
        onEditLocalSources: (String _) async {},
      ),
    );

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  // BUG-027 的开关列对齐必须继续成立：远端行的 ✎ 占的是本地行 tune 的同一槽位
  // （开关左侧），所以两类行的开关/↑/↓/删除四列仍右贴边对齐。
  testWidgets(
      'the edit button sits left of the switch and keeps the switch '
      'column aligned across local and remote rows (BUG-027)',
      (WidgetTester tester) async {
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.localAudio(
              label: 'a.db', path: '/a.db', enabled: true),
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
    expect((localSwitchX - remoteSwitchX).abs(), lessThan(1.0));
    expect(tester.getCenter(find.byIcon(Icons.edit_outlined)).dx,
        lessThan(remoteSwitchX));
  });

  testWidgets(
      'a loopback remoteAudio source shows the cross-machine re-point warning '
      '(TODO-1171)', (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: <AudioSourceConfig>[
            AudioSourceConfig.remoteAudio(
              url: 'http://localhost:41440/localaudio/get/?term={term}',
            ),
            AudioSourceConfig.remoteAudio(
              url: 'https://real.example.com/?term={term}',
            ),
          ],
          onSave: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Exactly one row (the loopback one) surfaces the cross-machine re-point
    // warning; the real remote row does not.
    expect(
        find.textContaining(t.audio_source_loopback_warning), findsOneWidget);
  });
}
