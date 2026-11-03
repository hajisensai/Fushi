import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Android 桌面小组件快照：纯构建函数的 JSON 形状 / 夹取 / 模块门控 / 空态，
/// 以及发布器的签名去重（与原生侧 `WidgetSnapshot.kt` 的解析契约对齐）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const WidgetSnapshotLabels labels = WidgetSnapshotLabels(
    kindBook: 'Book',
    kindManga: 'Manga',
    kindVideo: 'Video',
    resume: 'Continue',
    today: 'Today',
    streak: 'Streak',
    srsDue: 'Due',
    srsOff: 'Review is off',
    review: 'Review',
    srsDone: 'Done',
    recent: 'Recent',
    weekly: 'This week',
    books: 'Books',
    manga: 'Manga',
    video: 'Video',
    lookup: 'Lookup',
    openToSetUp: 'Open Fushi to set up',
  );

  String time(int ms) => '${ms ~/ 60000}m';
  String chars(int n) => '$n chars';

  WidgetMediaInput item(
    String id, {
    WidgetMediaKind kind = WidgetMediaKind.book,
    int recentAt = 0,
    double progress = 0.5,
    String cover = '',
    String subtitle = '',
    String title = 'T',
  }) => WidgetMediaInput(
    kind: kind,
    id: id,
    title: title,
    subtitle: subtitle,
    progress: progress,
    coverPath: cover,
    recentAt: recentAt,
  );

  Map<String, Object?> build({
    List<WidgetMediaInput> media = const <WidgetMediaInput>[],
    bool moduleBooks = true,
    bool moduleManga = true,
    bool moduleVideo = true,
    bool moduleLookup = true,
    WidgetTodayInput today = const WidgetTodayInput(),
    WidgetWeekInput week = const WidgetWeekInput(),
    bool srsEnabled = true,
    int srsDue = 0,
  }) => buildWidgetSnapshot(
    day: '2026-10-23',
    labels: labels,
    moduleBooks: moduleBooks,
    moduleManga: moduleManga,
    moduleVideo: moduleVideo,
    moduleLookup: moduleLookup,
    media: media,
    today: today,
    week: week,
    srsEnabled: srsEnabled,
    srsDue: srsDue,
    formatTime: time,
    formatChars: chars,
  );

  List<Map<String, Object?>> shelfOf(Map<String, Object?> s) =>
      (s['shelf']! as List<Object?>).cast<Map<String, Object?>>();

  group('buildWidgetSnapshot', () {
    test('has the exact JSON shape the native side parses', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[
          item(
            'b1',
            title: '  Title  ',
            subtitle: ' Author ',
            progress: 0.25,
            cover: '/data/cover.jpg',
            recentAt: 10,
          ),
        ],
        today: const WidgetTodayInput(
          ms: 42 * 60000,
          chars: 12400,
          goalChars: 24800,
          streak: 5,
        ),
        week: const WidgetWeekInput(
          minutes: <int>[1, 2, 3, 4, 5, 6, 7],
          days: <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'],
          totalMs: 320 * 60000,
          totalChars: 88000,
        ),
        srsDue: 12,
      );

      // 能原样过 JSON（通道里发的就是 jsonEncode）。
      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(s)) as Map<String, dynamic>;
      expect(json['day'], '2026-10-23');
      expect(
        (json['labels'] as Map<String, dynamic>).keys,
        containsAll(<String>[
          'kind_book',
          'kind_manga',
          'kind_video',
          'resume',
          'today',
          'streak',
          'srsDue',
          'srsOff',
          'review',
          'srsDone',
          'recent',
          'weekly',
          'books',
          'manga',
          'video',
          'lookup',
          'openToSetUp',
        ]),
      );
      expect((json['labels'] as Map<String, dynamic>).length, 17);
      expect(json['modules'], <String, bool>{
        'books': true,
        'manga': true,
        'video': true,
        'lookup': true,
      });
      expect(json['continue'], <String, Object?>{
        'kind': 'book',
        'id': 'b1',
        'title': 'Title',
        'subtitle': 'Author',
        'progress': 0.25,
        'cover': '/data/cover.jpg',
      });
      expect(json['shelf'], <Object?>[json['continue']]);
      expect(json['today'], <String, Object?>{
        'time': '42m',
        'chars': '12400 chars',
        'goal': 0.5,
        'streak': 5,
      });
      expect(json['week'], <String, Object?>{
        'minutes': <int>[1, 2, 3, 4, 5, 6, 7],
        'days': <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'],
        'time': '320m',
        'chars': '88000 chars',
      });
      expect(json['srs'], <String, Object?>{'enabled': true, 'due': 12});
    });

    test('empty library: no continue, empty shelf, zeros everywhere', () {
      final Map<String, Object?> s = build();
      expect(s['continue'], isNull);
      expect(shelfOf(s), isEmpty);
      final Map<String, Object?> today = s['today']! as Map<String, Object?>;
      expect(today['goal'], 0);
      expect(today['streak'], 0);
      final Map<String, Object?> week = s['week']! as Map<String, Object?>;
      expect(week['minutes'], List<int>.filled(7, 0));
      expect(week['days'], List<String>.filled(7, ''));
    });

    test('continue is the most recent item; shelf is capped at 4, recent '
        'first, ties keep input order', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[
          item('old', recentAt: 1),
          item('new', recentAt: 9),
          item('tie-a', recentAt: 5),
          item('tie-b', recentAt: 5),
          item('mid', recentAt: 3),
          item('oldest', recentAt: 0),
        ],
      );
      expect(shelfOf(s).map((Map<String, Object?> m) => m['id']), <String>[
        'new',
        'tie-a',
        'tie-b',
        'mid',
      ]);
      expect((s['continue']! as Map<String, Object?>)['id'], 'new');
    });

    test('progress is clamped into 0..1 and NaN becomes 0', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[
          item('over', progress: 1.7, recentAt: 4),
          item('under', progress: -0.3, recentAt: 3),
          item('nan', progress: double.nan, recentAt: 2),
          item('inf', progress: double.infinity, recentAt: 1),
        ],
      );
      expect(
        shelfOf(s).map((Map<String, Object?> m) => m['progress']),
        <double>[1, 0, 0, 0],
      );
    });

    test('goal fraction: clamped, and 0 without a goal', () {
      double goalOf(WidgetTodayInput t) =>
          ((build(today: t)['today']! as Map<String, Object?>)['goal']! as num)
              .toDouble();
      expect(goalOf(const WidgetTodayInput(chars: 500)), 0);
      expect(goalOf(const WidgetTodayInput(chars: 500, goalChars: -3)), 0);
      expect(goalOf(const WidgetTodayInput(chars: 500, goalChars: 1000)), 0.5);
      expect(goalOf(const WidgetTodayInput(chars: 5000, goalChars: 1000)), 1);
    });

    test('negative numbers never leak out', () {
      final Map<String, Object?> s = build(
        today: const WidgetTodayInput(ms: -5, chars: -5, streak: -2),
        week: const WidgetWeekInput(
          minutes: <int>[-1, 4],
          totalMs: -9,
          totalChars: -9,
        ),
        srsDue: -4,
      );
      expect(s['today'], <String, Object?>{
        'time': '0m',
        'chars': '0 chars',
        'goal': 0,
        'streak': 0,
      });
      final Map<String, Object?> week = s['week']! as Map<String, Object?>;
      expect(week['minutes'], <int>[0, 0, 0, 0, 0, 0, 4]);
      expect(week['time'], '0m');
      expect((s['srs']! as Map<String, Object?>)['due'], 0);
    });

    test('week lists are padded in front or cut to the last 7', () {
      final Map<String, Object?> padded = build(
        week: const WidgetWeekInput(
          minutes: <int>[3, 4],
          days: <String>['S', 'M'],
        ),
      );
      final Map<String, Object?> pw = padded['week']! as Map<String, Object?>;
      expect(pw['minutes'], <int>[0, 0, 0, 0, 0, 3, 4]);
      expect(pw['days'], <String>['', '', '', '', '', 'S', 'M']);

      final Map<String, Object?> cut = build(
        week: const WidgetWeekInput(
          minutes: <int>[9, 8, 1, 2, 3, 4, 5, 6, 7],
          days: <String>['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'],
        ),
      );
      final Map<String, Object?> cw = cut['week']! as Map<String, Object?>;
      expect(cw['minutes'], <int>[1, 2, 3, 4, 5, 6, 7]);
      expect(cw['days'], <String>['c', 'd', 'e', 'f', 'g', 'h', 'i']);
    });

    test('a disabled module drops its items before continue / shelf', () {
      final List<WidgetMediaInput> media = <WidgetMediaInput>[
        item('manga-newest', kind: WidgetMediaKind.manga, recentAt: 9),
        item('video-mid', kind: WidgetMediaKind.video, recentAt: 5),
        item('book-old', recentAt: 1),
      ];
      Map<String, Object?> without({
        bool books = true,
        bool manga = true,
        bool video = true,
      }) => build(
        media: media,
        moduleBooks: books,
        moduleManga: manga,
        moduleVideo: video,
      );

      final Map<String, Object?> noManga = without(manga: false);
      expect((noManga['continue']! as Map<String, Object?>)['id'], 'video-mid');
      expect(shelfOf(noManga), hasLength(2));
      expect((noManga['modules']! as Map<String, Object?>)['manga'], isFalse);

      final Map<String, Object?> onlyBooks = without(
        manga: false,
        video: false,
      );
      expect(shelfOf(onlyBooks).single['id'], 'book-old');

      final Map<String, Object?> none = without(
        books: false,
        manga: false,
        video: false,
      );
      expect(none['continue'], isNull);
      expect(shelfOf(none), isEmpty);
    });

    test('lookup module only flips its flag', () {
      final Map<String, Object?> s = build(moduleLookup: false);
      expect((s['modules']! as Map<String, Object?>)['lookup'], isFalse);
    });

    test('items without an id are skipped', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[item('', recentAt: 9), item('ok')],
      );
      expect(shelfOf(s).single['id'], 'ok');
    });

    test('srs disabled reports due 0 whatever the count was', () {
      final Map<String, Object?> s = build(srsEnabled: false, srsDue: 30);
      expect(s['srs'], <String, Object?>{'enabled': false, 'due': 0});
    });

    test('is deterministic: same inputs give identical JSON', () {
      Map<String, Object?> make() => build(
        media: <WidgetMediaInput>[item('a', recentAt: 2), item('b')],
        today: const WidgetTodayInput(ms: 60000, chars: 10, goalChars: 100),
      );
      expect(jsonEncode(make()), jsonEncode(make()));
    });
  });

  test('clampWidgetFraction', () {
    expect(clampWidgetFraction(0.4), 0.4);
    expect(clampWidgetFraction(-1), 0);
    expect(clampWidgetFraction(2), 1);
    expect(clampWidgetFraction(double.nan), 0);
    expect(clampWidgetFraction(double.negativeInfinity), 0);
  });

  group('WidgetSnapshotPublisher', () {
    final List<MethodCall> calls = <MethodCall>[];
    bool failNext = false;

    setUp(() {
      calls.clear();
      failNext = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.widgets, (
            MethodCall call,
          ) async {
            calls.add(call);
            if (failNext) {
              failNext = false;
              throw PlatformException(code: 'boom');
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.widgets, null);
    });

    test('uses the native channel name', () {
      expect(FushiChannels.widgets.name, 'app.fushi.reader/widgets');
    });

    test('sends one JSON string through updateSnapshot', () async {
      final WidgetSnapshotPublisher publisher = WidgetSnapshotPublisher(
        platformSupported: true,
      );
      final Map<String, Object?> snapshot = build(srsDue: 3);
      await publisher.publish(snapshot);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'updateSnapshot');
      expect(calls.single.arguments, isA<String>());
      expect(
        jsonDecode(calls.single.arguments as String),
        jsonDecode(jsonEncode(snapshot)),
      );
    });

    test('identical snapshots are deduped, changed ones go through', () async {
      final WidgetSnapshotPublisher publisher = WidgetSnapshotPublisher(
        platformSupported: true,
      );
      await publisher.publish(build(srsDue: 3));
      await publisher.publish(build(srsDue: 3));
      expect(calls, hasLength(1));
      await publisher.publish(build(srsDue: 4));
      expect(calls, hasLength(2));
    });

    test('a failed send is retried by the next identical publish', () async {
      final WidgetSnapshotPublisher publisher = WidgetSnapshotPublisher(
        platformSupported: true,
      );
      failNext = true;
      await publisher.publish(build(srsDue: 3));
      expect(calls, hasLength(1));
      await publisher.publish(build(srsDue: 3));
      expect(calls, hasLength(2), reason: 'signature cleared on failure');
    });

    test('is a no-op where there is no native side', () async {
      final WidgetSnapshotPublisher publisher = WidgetSnapshotPublisher(
        platformSupported: false,
      );
      await publisher.publish(build());
      expect(calls, isEmpty);
    });
  });

  test('WidgetMediaKind wire values match the native contract', () {
    expect(WidgetMediaKind.values.map((WidgetMediaKind k) => k.wire), <String>[
      'book',
      'manga',
      'video',
    ]);
  });
}
