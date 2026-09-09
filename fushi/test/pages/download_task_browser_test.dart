import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_browser.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';

DownloadTaskEntry _task(
  String id, {
  String? title,
  DownloadTaskKind kind = DownloadTaskKind.game,
  DownloadTaskStatus status = DownloadTaskStatus.active,
  int? createdAt,
  double? progress,
  String? collectionKey,
  String? collectionTitle,
  List<String> searchTerms = const <String>[],
}) => DownloadTaskEntry(
  id: id,
  title: title ?? id,
  kind: kind,
  status: status,
  createdAt: createdAt,
  progress: progress,
  collectionKey: collectionKey,
  collectionTitle: collectionTitle,
  searchTerms: searchTerms,
  builder: (BuildContext context) => DownloadTaskCard(
    key: ValueKey<String>(id),
    taskId: id,
    title: title ?? id,
    status: downloadTaskStatusLabel(status),
    progress: progress,
    details: Text('details-$id'),
  ),
);

List<String> _ids(List<DownloadTaskEntry> tasks) =>
    tasks.map((DownloadTaskEntry task) => task.id).toList();

Widget _host(
  List<DownloadTaskEntry> tasks, {
  double scale = 1,
  String? fontFamily,
}) => TranslationProvider(
  child: MaterialApp(
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: fontFamily),
    ),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey<String>('download-browser-capture'),
          child: DownloadTaskBrowser(tasks: tasks),
        ),
      ),
    ),
  ),
);

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('type and status filters combine across download sources', () {
    final List<DownloadTaskEntry> tasks = <DownloadTaskEntry>[
      _task('torrent-game'),
      _task('http-game'),
      _task('pack-game', status: DownloadTaskStatus.paused),
      _task('video', kind: DownloadTaskKind.video),
      _task('manga', kind: DownloadTaskKind.manga),
    ];
    expect(
      _ids(
        selectDownloadTasks(
          tasks,
          kind: DownloadTaskKind.game,
          status: DownloadTaskStatus.active,
        ),
      ),
      <String>['http-game', 'torrent-game'],
    );
    expect(selectDownloadTasks(tasks, kind: DownloadTaskKind.novel), isEmpty);
  });

  for (final DownloadTaskSort sort in <DownloadTaskSort>[
    DownloadTaskSort.created,
    DownloadTaskSort.progress,
  ]) {
    test(
      '$sort orders all sources and keeps unknown values last both ways',
      () {
        final List<DownloadTaskEntry> tasks = <DownloadTaskEntry>[
          _task('unknown'),
          _task('http', createdAt: 10, progress: 0.2),
          _task('torrent', createdAt: 30, progress: 0.8),
          _task('pack', createdAt: 20, progress: 0.5),
        ];
        expect(_ids(selectDownloadTasks(tasks, sort: sort)), <String>[
          'torrent',
          'pack',
          'http',
          'unknown',
        ]);
        expect(
          _ids(selectDownloadTasks(tasks, sort: sort, reverse: true)),
          <String>['http', 'pack', 'torrent', 'unknown'],
        );
        expect(
          tasks.first.id,
          'unknown',
          reason: 'Sorting must not mutate source queues',
        );
      },
    );
  }

  test('title and status ordering can both be reversed', () {
    final List<DownloadTaskEntry> tasks = <DownloadTaskEntry>[
      _task('z', title: 'Zebra', status: DownloadTaskStatus.attention),
      _task('a', title: 'alpha', status: DownloadTaskStatus.completed),
      _task('b', title: 'Beta', status: DownloadTaskStatus.paused),
    ];
    expect(
      _ids(selectDownloadTasks(tasks, sort: DownloadTaskSort.title)),
      <String>['a', 'b', 'z'],
    );
    expect(
      _ids(
        selectDownloadTasks(tasks, sort: DownloadTaskSort.title, reverse: true),
      ),
      <String>['z', 'b', 'a'],
    );
    expect(
      _ids(selectDownloadTasks(tasks, sort: DownloadTaskSort.status)),
      <String>['z', 'b', 'a'],
    );
    expect(
      _ids(
        selectDownloadTasks(
          tasks,
          sort: DownloadTaskSort.status,
          reverse: true,
        ),
      ),
      <String>['a', 'b', 'z'],
    );
  });

  test('search includes collection titles and source aliases', () {
    final List<DownloadTaskEntry> tasks = <DownloadTaskEntry>[
      _task(
        'clannad',
        collectionKey: 'key',
        collectionTitle: 'Key Collection',
        searchTerms: <String>['クラナド'],
      ),
      _task('air', collectionKey: 'key', collectionTitle: 'Key Collection'),
      _task('other'),
    ];
    expect(_ids(selectDownloadTasks(tasks, query: 'KEY collection')), <String>[
      'air',
      'clannad',
    ]);
    expect(_ids(selectDownloadTasks(tasks, query: 'クラナド')), <String>[
      'clannad',
    ]);
  });

  testWidgets('collection collapse and search survive queue refresh', (
    WidgetTester tester,
  ) async {
    _viewport(tester, const Size(1000, 900));
    final List<DownloadTaskEntry> tasks = <DownloadTaskEntry>[
      _task('first', collectionKey: 'key', collectionTitle: 'Key Collection'),
      _task('second', collectionKey: 'key', collectionTitle: 'Key Collection'),
      _task('other'),
    ];
    await tester.pumpWidget(_host(tasks));
    await tester.pumpAndSettle();
    final Finder group = find.byKey(
      const ValueKey<String>('download-group-collection:key'),
    );
    expect(find.text('first'), findsOneWidget);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('other'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('download-task-search')),
      'Key Collection',
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(<DownloadTaskEntry>[
        ...tasks,
        _task('third', collectionKey: 'key', collectionTitle: 'Key Collection'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('third'), findsNothing);
    expect(find.text('other'), findsNothing);
    expect(find.text('0 / 3'), findsOneWidget);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('third'), findsOneWidget);
    expect(find.text('other'), findsNothing);
  });

  testWidgets(
    'collapse all toggles collections and card details disclose independently',
    (WidgetTester tester) async {
      _viewport(tester, const Size(1000, 900));
      await tester.pumpWidget(
        _host(<DownloadTaskEntry>[
          _task(
            'first',
            collectionKey: 'key',
            collectionTitle: 'Key Collection',
          ),
          _task('second'),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('details-first'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('download-task-toggle-first')),
      );
      await tester.pumpAndSettle();
      expect(find.text('details-first'), findsOneWidget);
      expect(find.text('details-second'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('download-task-toggle-first')),
      );
      await tester.pumpAndSettle();
      expect(find.text('details-first'), findsNothing);
      final Finder collapse = find.byKey(
        const ValueKey<String>('download-task-collapse-all'),
      );
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      expect(find.byType(DownloadTaskCard), findsNothing);
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      expect(find.byType(DownloadTaskCard), findsNWidgets(2));
    },
  );

  for (final double scale in <double>[1, 2]) {
    testWidgets('360px browser and expanded card fit at text scale $scale', (
      WidgetTester tester,
    ) async {
      _viewport(tester, const Size(360, 1000));
      await tester.pumpWidget(
        _host(<DownloadTaskEntry>[
          _task(
            'long',
            title: 'A long game title with many words and editions',
            progress: 0.37,
            collectionKey: 'long-collection',
            collectionTitle:
                'A collection with a particularly long descriptive title',
          ),
        ], scale: scale),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey<String>('download-task-toggle-long')),
      );
      await tester.pumpAndSettle();
      expect(find.text('details-long'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('renders a desktop preview for visual inspection', (
    WidgetTester tester,
  ) async {
    _viewport(tester, const Size(1200, 900));
    // Visual evidence only: load readable local fonts when available, without
    // requiring Windows fonts on CI or changing behavior-test font metrics.
    String? previewFont;
    await tester.runAsync(() async {
      final FontLoader icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final String? windows = Platform.environment['WINDIR'];
      if (windows != null) {
        final File font = File('$windows/Fonts/segoeui.ttf');
        if (await font.exists()) {
          final FontLoader text = FontLoader('DownloadPreview')
            ..addFont(font.readAsBytes().then(ByteData.sublistView));
          await text.load();
          previewFont = 'DownloadPreview';
        }
      }
    });
    await tester.pumpWidget(
      _host(<DownloadTaskEntry>[
        _task(
          'torrent',
          title: 'CLANNAD',
          progress: 0.43,
          collectionKey: 'key',
          collectionTitle: 'Key Collection',
        ),
        _task(
          'http',
          title: 'AIR',
          status: DownloadTaskStatus.completed,
          progress: 1,
          collectionKey: 'key',
          collectionTitle: 'Key Collection',
        ),
        _task(
          'pack',
          title: 'Recommended novels',
          kind: DownloadTaskKind.novel,
          status: DownloadTaskStatus.paused,
          progress: 0.2,
        ),
      ], fontFamily: previewFont),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final RenderRepaintBoundary boundary = tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey<String>('download-browser-capture')),
        );
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final File output = File('../.codex-test/download-task-browser.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  });

  group('多选批量操作', () {
    DownloadTaskEntry actionable(
      String id, {
      required DownloadTaskActions actions,
    }) => DownloadTaskEntry(
      id: id,
      title: id,
      kind: DownloadTaskKind.video,
      status: DownloadTaskStatus.active,
      actions: actions,
      builder: (BuildContext context) => DownloadTaskCard(
        key: ValueKey<String>(id),
        taskId: id,
        title: id,
        status: 'x',
        details: Text('details-$id'),
      ),
    );

    Future<void> enterSelection(WidgetTester tester) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('download-task-select-mode')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('默认不在选择态；点「选择」才出现勾选框与操作栏', (
      WidgetTester tester,
    ) async {
      _viewport(tester, const Size(900, 900));
      await tester.pumpWidget(
        _host(<DownloadTaskEntry>[_task('a'), _task('b')]),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BatchActionBar), findsNothing);
      expect(find.byType(Checkbox), findsNothing);

      await enterSelection(tester);
      expect(find.byType(BatchActionBar), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(2));
    });

    testWidgets('选择态下点整行只切换选中，不触发卡片自身的按钮', (
      WidgetTester tester,
    ) async {
      _viewport(tester, const Size(900, 900));
      int cardTaps = 0;
      final DownloadTaskEntry trap = DownloadTaskEntry(
        id: 'trap',
        title: 'trap',
        kind: DownloadTaskKind.video,
        status: DownloadTaskStatus.active,
        builder: (BuildContext context) => TextButton(
          key: const ValueKey<String>('trap-button'),
          onPressed: () => cardTaps++,
          child: const Text('danger'),
        ),
      );
      await tester.pumpWidget(_host(<DownloadTaskEntry>[trap]));
      await tester.pumpAndSettle();
      await enterSelection(tester);

      // warnIfMissed: false 是**被测行为本身**：选择态下 IgnorePointer 罩住卡片，
      // 这一 tap 打不到按钮才是对的，命中了反而说明回归了。
      await tester.tap(
        find.byKey(const ValueKey<String>('trap-button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(cardTaps, 0, reason: '选择态里卡片按钮必须让位，否则勾选会变成删除');
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox)).value,
        isTrue,
        reason: '这一下应该被算作「勾选这一行」',
      );
    });

    testWidgets('批量重试只作用于支持重试的条目，不支持的单独计数', (
      WidgetTester tester,
    ) async {
      _viewport(tester, const Size(900, 900));
      final List<String> retried = <String>[];
      await tester.pumpWidget(
        _host(<DownloadTaskEntry>[
          actionable(
            'has-retry',
            actions: DownloadTaskActions(
              retry: () async => retried.add('has-retry'),
            ),
          ),
          actionable('no-retry', actions: DownloadTaskActions.none),
        ]),
      );
      await tester.pumpAndSettle();
      await enterSelection(tester);
      await tester.tap(find.text(t.batch_select_all));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('download-batch-retry')),
      );
      await tester.pumpAndSettle();

      expect(retried, <String>['has-retry']);
      expect(find.textContaining(t.download_batch_done(n: 1)), findsOneWidget);
      expect(
        find.textContaining(t.download_batch_unsupported(n: 1)),
        findsOneWidget,
        reason: '「不支持」要和「失败」分开说：再点一百次也一样',
      );
    });

    testWidgets('选中集里没有条目支持某动作时按钮禁用', (
      WidgetTester tester,
    ) async {
      _viewport(tester, const Size(900, 900));
      await tester.pumpWidget(
        _host(<DownloadTaskEntry>[
          actionable(
            'only-clear',
            actions: DownloadTaskActions(clear: () async {}),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      await enterSelection(tester);
      await tester.tap(find.text(t.batch_select_all));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FushiIconButton>(
              find.byKey(const ValueKey<String>('download-batch-clear')),
            )
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<FushiIconButton>(
              find.byKey(const ValueKey<String>('download-batch-pause')),
            )
            .enabled,
        isFalse,
        reason: '单跑道队列没有暂停态，摆一个点了没反应的按钮比没有更糟',
      );
    });

    testWidgets('全选 / 反选以当前可见集合为域（被搜索筛掉的不算）', (
      WidgetTester tester,
    ) async {
      _viewport(tester, const Size(900, 900));
      final List<String> cleared = <String>[];
      DownloadTaskEntry clearable(String id) => DownloadTaskEntry(
        id: id,
        title: id,
        kind: DownloadTaskKind.video,
        status: DownloadTaskStatus.active,
        actions: DownloadTaskActions(clear: () async => cleared.add(id)),
        builder: (BuildContext context) => DownloadTaskCard(
          key: ValueKey<String>(id),
          taskId: id,
          title: id,
          status: 'x',
          details: Text('details-$id'),
        ),
      );
      await tester.pumpWidget(
        _host(<DownloadTaskEntry>[clearable('alpha'), clearable('beta')]),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('download-task-search')),
        'alpha',
      );
      await tester.pumpAndSettle();
      await enterSelection(tester);
      await tester.tap(find.text(t.batch_select_all));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('download-batch-clear')),
      );
      await tester.pumpAndSettle();

      expect(
        cleared,
        <String>['alpha'],
        reason: '被搜索筛掉的 beta 不该被「全选」卷进来',
      );
    });

    testWidgets('批量操作栏在 360 逻辑像素宽不溢出', (WidgetTester tester) async {
      _viewport(tester, const Size(360, 720));
      await tester.pumpWidget(
        _host(<DownloadTaskEntry>[
          actionable(
            'a',
            actions: DownloadTaskActions(
              retry: () async {},
              clear: () async {},
            ),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      await enterSelection(tester);
      await tester.tap(find.text(t.batch_select_all));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
