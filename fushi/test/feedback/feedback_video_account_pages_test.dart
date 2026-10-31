// 反馈视频附件与跨设备「我的反馈」的页面行为（反馈 #TR5TagzHAZ / #TDXpJd97_C / #zllx8xiNbG）：
// - 提交页可选 1 个视频，提交后视频流式传到 v0；
// - 详情页：服务端有视频时列条目（不去取视频字节）、补传窗口内可「追加视频」、
//   待传附件给「重试上传」；
// - 已登录账户时「我的反馈」列出别的设备提交的工单，详情走账户签名、没有「从本机移除」；
// - 处理台详情：视频给「播放视频」入口，不当截图去解码。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_center_page.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_detail_page.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_dev_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

class _PickVideo extends FilePicker {
  _PickVideo(this.path);

  final String path;
  FileType? lastType;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    lastType = type;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(name: p.basename(path), size: 0, path: path),
    ]);
  }
}

/// [controlledPrepare] 的一次调用：测试置 [released] 放行（或先置 [failure] 让它失败）。
class _PrepareCall {
  _PrepareCall(this.options);

  final FeedbackVideoPrepareOptions options;
  bool released = false;
  bool cancelled = false;
  Exception? failure;
}

Map<String, dynamic> _detail(
  String id, {
  List<Map<String, dynamic>> attachments = const <Map<String, dynamic>>[],
  int? createdAt,
}) => <String, dynamic>{
  'id': id,
  'category': 'bug',
  'title': 'title-$id',
  'status': 'open',
  'createdAt': createdAt ?? 100,
  'updatedAt': createdAt ?? 100,
  'body': 'body-$id',
  'contact': '',
  'attachments': attachments,
  'messages': <Object>[],
};

const Map<String, dynamic> _videoAttachment = <String, dynamic>{
  'slot': 'v0',
  'kind': 'video',
  'bytes': 3 * 1024 * 1024,
  'type': 'video/mp4',
};

class _Server {
  final List<http.Request> requests = <http.Request>[];
  final Map<String, Map<String, dynamic>> details =
      <String, Map<String, dynamic>>{};
  List<Map<String, dynamic>> mine = <Map<String, dynamic>>[];
  int now = DateTime.now().millisecondsSinceEpoch;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final String path = r.url.path;
    if (path == '/v1/me') {
      return _json(<String, dynamic>{
        'id': 'SelfAccount001',
        'nickname': 'Me',
        'discriminator': 1,
        'avatar': null,
        'visibility': 'public',
        'createdAt': 1,
        'role': 'dev',
      });
    }
    if (path == '/v1/feedback/mine') {
      return _json(<String, dynamic>{'items': mine, 'next': null});
    }
    if (path == '/v1/feedback/status') {
      return _json(<String, dynamic>{'items': <Object>[]});
    }
    if (path == '/v1/feedback' && r.method == 'POST') {
      return _json(<String, dynamic>{
        'id': 'newnewnew0',
        'ticket': 'T' * 32,
        'status': 'open',
        'createdAt': now,
        'updatedAt': now,
      }, 201);
    }
    final RegExpMatch? one = RegExp(
      r'^/v1/(dev/)?feedback/([A-Za-z0-9_-]+)$',
    ).firstMatch(path);
    if (one != null && r.method == 'GET') {
      final Map<String, dynamic>? d = details[one.group(2)];
      return d == null ? _json(<String, dynamic>{}, 404) : _json(d);
    }
    return _json(<String, dynamic>{'slot': 'x'}, 201);
  }
}

void main() {
  late Directory root;
  late _Server server;
  late File clip;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_video_ui_');
    server = _Server();
    clip = File(p.join(root.path, 'screen-record.mp4'))
      ..writeAsBytesSync(<int>[
        0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, //
        ...List<int>.filled(500, 7),
      ]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  LeaderboardService board() => LeaderboardService(
    database: () => throw StateError('no database in UI tests'),
    supportRoot: () async => root,
    profileId: () async => 1,
    httpClientFactory: () async => MockClient(server.handle),
    defaultBaseUrl: Uri.parse('https://rank.example'),
    isbnBackfill: (FushiDatabase _) async => 0,
  );

  Future<LeaderboardService> signedInBoard(WidgetTester tester) async {
    final LeaderboardService b = board();
    await tester.runAsync(() async {
      await LeaderboardStore(supportRoot: root, profileId: 1).write(
        LeaderboardLocalAccount(
          recoveryCode: LeaderboardIdentity.generate().toRecoveryCode(),
          accountId: 'SelfAccount001',
          consentAt: 1,
        ),
      );
      await b.load();
    });
    return b;
  }

  FeedbackService feedback(
    LeaderboardService b, {
    FeedbackVideoPreparer? prepare,
  }) => FeedbackService(
    supportRoot: () async => root,
    client: b.feedbackClient,
    meta: () async => <String, Object?>{'platform': 'test'},
    logText: ({required bool includeDebugLog}) => 'log',
    logEncoder: (String s) =>
        Uint8List.fromList(<int>[0x1f, 0x8b, ...utf8.encode(s)]),
    // 测试宿主没有 ffmpeg：假转码 = 原样复制进工作目录。
    prepareVideo:
        prepare ??
        (
          File source,
          Directory work,
          void Function(double) onProgress,
          FeedbackVideoPrepareOptions _,
        ) async {
          final File out = await source.copy(p.join(work.path, 'out.mp4'));
          return PreparedFeedbackVideo(
            file: out,
            contentType: 'video/mp4',
            bytes: await out.length(),
            transcoded: true,
          );
        },
  );

  Widget wrap(LeaderboardService b, FeedbackService f, Widget child) =>
      ProviderScope(
        overrides: <Override>[
          leaderboardServiceProvider.overrideWith((Ref _) => b),
          feedbackServiceProvider.overrideWith((Ref _) => f),
        ],
        child: TranslationProvider(child: MaterialApp(home: child)),
      );

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> settleIo(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 300 && (i < 10 || !done()); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> seed(FeedbackTicket t) =>
      FeedbackTicketStore(root).write(<FeedbackTicket>[t]);

  FeedbackTicket local(String id, {int? createdAt}) => FeedbackTicket(
    id: id,
    ticket: 'ticket-$id',
    title: 'title-$id',
    category: FeedbackCategory.bug,
    createdAt: createdAt ?? server.now,
    status: FeedbackStatus.open,
    updatedAt: createdAt ?? server.now,
    seenAt: createdAt ?? server.now,
  );

  bool sent(String path, {String method = 'PUT'}) => server.requests.any(
    (http.Request r) => r.url.path == path && r.method == method,
  );

  testWidgets('#TR5TagzHAZ 提交页可选视频：选中显示文件名，提交后视频传到 v0', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final _PickVideo picker = _PickVideo(clip.path);
    FilePicker.platform = picker;
    final LeaderboardService b = board();
    final FeedbackService f = feedback(b);
    await tester.pumpWidget(wrap(b, f, const FeedbackCenterPage()));
    await settleIo(tester, () => f.loaded);
    await tester.tap(find.byKey(const ValueKey<String>('feedback-center-new')));
    await settleIo(
      tester,
      () => find
          .byKey(const ValueKey<String>('feedback-add-video'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey<String>('feedback-video-hint')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('feedback-add-video')));
    await settleIo(
      tester,
      () => find
          .byKey(const ValueKey<String>('feedback-video'))
          .evaluate()
          .isNotEmpty,
    );
    expect(picker.lastType, FileType.video);
    expect(find.text('screen-record.mp4'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('feedback-title')),
      '视频反馈',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('feedback-body')),
      '看录屏',
    );
    await tester.tap(find.byKey(const ValueKey<String>('feedback-submit')));
    await settleIo(
      tester,
      () => sent('/v1/feedback/newnewnew0/attachments/v0'),
    );
    final http.Request put = server.requests.firstWhere(
      (http.Request r) => r.url.path.endsWith('/attachments/v0'),
    );
    expect(put.headers['Content-Type'], 'video/mp4');
    expect(put.contentLength, clip.lengthSync());
    expect(put.bodyBytes, clip.readAsBytesSync());
  });

  /// 打开提交页并选好视频。
  Future<void> openAndPickVideo(
    WidgetTester tester,
    FeedbackService f,
    LeaderboardService b,
  ) async {
    FilePicker.platform = _PickVideo(clip.path);
    await tester.pumpWidget(wrap(b, f, const FeedbackCenterPage()));
    await settleIo(tester, () => f.loaded);
    await tester.tap(find.byKey(const ValueKey<String>('feedback-center-new')));
    await settleIo(
      tester,
      () => find
          .byKey(const ValueKey<String>('feedback-add-video'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey<String>('feedback-add-video')));
    await settleIo(
      tester,
      () => find
          .byKey(const ValueKey<String>('feedback-video'))
          .evaluate()
          .isNotEmpty,
    );
  }

  bool titleEnabled(WidgetTester tester) =>
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('feedback-title')),
              matching: find.byType(TextField),
            ),
          )
          .enabled ??
      true;

  /// 可控的假压缩：每次调用登记一个 [_PrepareCall]，测试决定它何时完成 / 失败。
  FeedbackVideoPreparer controlledPrepare(List<_PrepareCall> calls) =>
      (
        File source,
        Directory work,
        void Function(double) onProgress,
        FeedbackVideoPrepareOptions options,
      ) async {
        final _PrepareCall call = _PrepareCall(options);
        calls.add(call);
        onProgress(0.23);
        bool cancelled = false;
        unawaited(options.cancel?.then((_) => cancelled = true));
        while (!call.released && !cancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        if (cancelled) {
          call.cancelled = true;
          throw const FeedbackVideoCancelledException();
        }
        final Exception? failure = call.failure;
        if (failure != null) throw failure;
        final File out = await source.copy(p.join(work.path, 'out.mp4'));
        return PreparedFeedbackVideo(
          file: out,
          contentType: 'video/mp4',
          bytes: await out.length(),
          transcoded: true,
        );
      };

  Finder byKey(String key) => find.byKey(ValueKey<String>(key));

  testWidgets('BUG-3489 选完视频就在后台压；压缩中文字框可编辑，× 取消压缩、撤销等待中的提交、什么也不发', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final List<_PrepareCall> calls = <_PrepareCall>[];
    final LeaderboardService b = board();
    final FeedbackService f = feedback(b, prepare: controlledPrepare(calls));
    await openAndPickVideo(tester, f, b);
    // 没点提交就已经在压。
    await settleIo(tester, () => calls.isNotEmpty);
    expect(calls, hasLength(1));
    expect(calls.single.options.quality, FeedbackVideoQuality.p720);
    expect(byKey('feedback-video-compressing'), findsOneWidget);
    // 压缩中的 × 是「取消并移除视频」，不是「去掉视频继续提交」。
    expect(
      find.byTooltip(t.feedback_compose_video_cancel_remove),
      findsOneWidget,
    );

    // 压缩进行中：文字框没被锁，能继续写。
    expect(titleEnabled(tester), isTrue);
    await tester.enterText(byKey('feedback-title'), '视频反馈');
    await tester.enterText(byKey('feedback-body'), '压缩时补充的描述');
    await tester.pump();
    expect(find.text('压缩时补充的描述'), findsOneWidget);

    // 点提交：还在压 → 排队等，不发请求、不开第二次压缩，表单仍可编辑。
    await tester.tap(byKey('feedback-submit'));
    await tester.pump();
    expect(calls, hasLength(1));
    expect(titleEnabled(tester), isTrue);
    expect(sent('/v1/feedback', method: 'POST'), isFalse);

    // × 可点：中止压缩、移除视频、撤销那次提交，留在页面。
    await tester.tap(byKey('feedback-remove-video'));
    await settleIo(
      tester,
      () =>
          calls.single.cancelled &&
          byKey('feedback-add-video').evaluate().isNotEmpty,
    );
    expect(calls.single.cancelled, isTrue);
    expect(byKey('feedback-video'), findsNothing);
    expect(byKey('feedback-compose-error'), findsNothing);
    expect(find.text('压缩时补充的描述'), findsOneWidget);
    expect(find.text(t.feedback_compose_submit), findsOneWidget);
    // 等一会儿也不会悄悄发出没有视频的反馈。
    await settleIo(tester, () => false);
    expect(sent('/v1/feedback', method: 'POST'), isFalse);
    final Directory work = Directory(
      p.join(root.path, 'feedback', 'video_work'),
    );
    expect(
      work.existsSync() ? work.listSync() : const <FileSystemEntity>[],
      isEmpty,
    );
  });

  testWidgets('BUG-3489 换 1080p 取消在途压缩并重压；提交时还在压就等压完自动发出（带压缩期间改的文字）', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final List<_PrepareCall> calls = <_PrepareCall>[];
    final LeaderboardService b = board();
    final FeedbackService f = feedback(b, prepare: controlledPrepare(calls));
    await openAndPickVideo(tester, f, b);
    await settleIo(tester, () => calls.isNotEmpty);
    expect(calls.single.options.quality, FeedbackVideoQuality.p720);

    await tester.tap(byKey('feedback-video-quality-1080p'));
    await settleIo(tester, () => calls.length == 2 && calls.first.cancelled);
    expect(calls.first.cancelled, isTrue);
    expect(calls.last.options.quality, FeedbackVideoQuality.p1080);
    expect(byKey('feedback-video-1080-hint'), findsOneWidget);

    await tester.enterText(byKey('feedback-title'), '原标题');
    await tester.tap(byKey('feedback-submit'));
    await tester.pump();
    expect(sent('/v1/feedback', method: 'POST'), isFalse);
    await tester.enterText(byKey('feedback-title'), '压缩时改的标题');
    calls.last.released = true;
    await settleIo(
      tester,
      () => sent('/v1/feedback/newnewnew0/attachments/v0'),
    );
    final http.Request post = server.requests.firstWhere(
      (http.Request r) => r.url.path == '/v1/feedback' && r.method == 'POST',
    );
    expect((jsonDecode(post.body) as Map<String, dynamic>)['title'], '压缩时改的标题');
    expect(calls, hasLength(2));
  });

  testWidgets('BUG-3489 压缩失败：附件行显示原因，等待中的提交撤销；重新压缩成功后可提交', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final List<_PrepareCall> calls = <_PrepareCall>[];
    final LeaderboardService b = board();
    final FeedbackService f = feedback(b, prepare: controlledPrepare(calls));
    await openAndPickVideo(tester, f, b);
    await settleIo(tester, () => calls.isNotEmpty);
    await tester.enterText(byKey('feedback-title'), '视频反馈');
    await tester.tap(byKey('feedback-submit'));
    await tester.pump();
    calls.single
      ..failure = const FeedbackVideoUnsupportedException()
      ..released = true;
    await settleIo(
      tester,
      () => byKey('feedback-video-error').evaluate().isNotEmpty,
    );
    expect(byKey('feedback-video-error'), findsOneWidget);
    expect(byKey('feedback-compose-error'), findsOneWidget);
    expect(sent('/v1/feedback', method: 'POST'), isFalse);
    expect(titleEnabled(tester), isTrue);

    await tester.tap(byKey('feedback-video-retry'));
    await settleIo(tester, () => calls.length == 2);
    calls.last.released = true;
    await settleIo(
      tester,
      () => byKey('feedback-video-ready').evaluate().isNotEmpty,
    );
    await tester.tap(byKey('feedback-submit'));
    await settleIo(
      tester,
      () => sent('/v1/feedback/newnewnew0/attachments/v0'),
    );
  });

  testWidgets('详情页：服务端有视频时列条目、不去取视频字节，也不再给「追加视频」', (WidgetTester tester) async {
    tallView(tester);
    await tester.runAsync(() => seed(local('vidvidvid0')));
    server.details['vidvidvid0'] = _detail(
      'vidvidvid0',
      attachments: <Map<String, dynamic>>[_videoAttachment],
      createdAt: server.now,
    );
    final LeaderboardService b = board();
    final FeedbackService f = feedback(b);
    await tester.runAsync(f.load);
    await tester.pumpWidget(
      wrap(b, f, const FeedbackDetailPage(feedbackId: 'vidvidvid0')),
    );
    final Finder row = find.byKey(
      const ValueKey<String>('feedback-detail-video'),
    );
    await settleIo(tester, () => row.evaluate().isNotEmpty);
    expect(row, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feedback-detail-add-video')),
      findsNothing,
    );
    expect(
      server.requests.where(
        (http.Request r) => r.url.path.endsWith('/attachments/v0'),
      ),
      isEmpty,
    );
  });

  testWidgets('#TDXpJd97_C 详情页追加视频：窗口内可追加，选文件后传到 v0', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    FilePicker.platform = _PickVideo(clip.path);
    await tester.runAsync(() => seed(local('addaddadd0')));
    server.details['addaddadd0'] = _detail('addaddadd0', createdAt: server.now);
    final LeaderboardService b = board();
    final FeedbackService f = feedback(b);
    await tester.runAsync(f.load);
    await tester.pumpWidget(
      wrap(b, f, const FeedbackDetailPage(feedbackId: 'addaddadd0')),
    );
    final Finder add = find.byKey(
      const ValueKey<String>('feedback-detail-add-video'),
    );
    await settleIo(tester, () => add.evaluate().isNotEmpty);
    await tester.tap(add);
    await settleIo(
      tester,
      () =>
          sent('/v1/feedback/addaddadd0/attachments/v0') &&
          f.pendingSlots('addaddadd0').isEmpty,
    );
    expect(sent('/v1/feedback/addaddadd0/attachments/v0'), isTrue);
    expect(f.pendingSlots('addaddadd0'), isEmpty);
  });

  testWidgets('详情页：待传的视频给「重试上传」，重试成功后提示消失', (WidgetTester tester) async {
    tallView(tester);
    await tester.runAsync(() async {
      await seed(local('pendpend00'));
      final File staged = await clip.copy(p.join(root.path, 'staged.mp4'));
      await FeedbackPendingStore(
        root,
      ).putFile('pendpend00', 'v0', staged, contentType: 'video/mp4');
    });
    server.details['pendpend00'] = _detail('pendpend00', createdAt: server.now);
    final LeaderboardService b = board();
    final FeedbackService f = feedback(b);
    await tester.runAsync(f.load);
    await tester.pumpWidget(
      wrap(b, f, const FeedbackDetailPage(feedbackId: 'pendpend00')),
    );
    final Finder retry = find.byKey(
      const ValueKey<String>('feedback-detail-retry'),
    );
    await settleIo(tester, () => retry.evaluate().isNotEmpty);
    // 有视频待传时不再给「追加视频」（每条最多一个）。
    expect(
      find.byKey(const ValueKey<String>('feedback-detail-add-video')),
      findsNothing,
    );
    await tester.tap(retry);
    await settleIo(tester, () => f.pendingSlots('pendpend00').isEmpty);
    await tester.pump();
    expect(sent('/v1/feedback/pendpend00/attachments/v0'), isTrue);
    expect(
      find.byKey(const ValueKey<String>('feedback-detail-pending')),
      findsNothing,
    );
  });

  testWidgets('#zllx8xiNbG 已登录：中心列出别的设备提交的工单，详情走账户签名、不能从本机移除', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    server.mine = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'otherdev01',
        'category': 'bug',
        'title': '手机上提交的',
        'status': 'in_progress',
        'createdAt': 50,
        'updatedAt': 60,
      },
    ];
    server.details['otherdev01'] = _detail('otherdev01');
    final LeaderboardService b = await signedInBoard(tester);
    final FeedbackService f = feedback(b);
    await tester.pumpWidget(wrap(b, f, const FeedbackCenterPage()));
    final Finder tile = find.byKey(
      const ValueKey<String>('feedback-ticket-otherdev01'),
    );
    await settleIo(tester, () => tile.evaluate().isNotEmpty);
    expect(tile, findsOneWidget);
    expect(find.text(t.feedback_from_other_device), findsOneWidget);
    final http.Request mine = server.requests.firstWhere(
      (http.Request r) => r.url.path == '/v1/feedback/mine',
    );
    expect(mine.headers['X-Fushi-Sig'], isNotNull);

    await tester.tap(tile);
    await settleIo(
      tester,
      () => find.text('body-otherdev01').evaluate().isNotEmpty,
    );
    expect(find.text('body-otherdev01'), findsOneWidget);
    final http.Request get = server.requests.lastWhere(
      (http.Request r) => r.url.path == '/v1/feedback/otherdev01',
    );
    expect(get.headers.containsKey('X-Fushi-Ticket'), isFalse);
    expect(get.headers['X-Fushi-Sig'], isNotNull);
    expect(find.byTooltip(t.feedback_detail_forget), findsNothing);
    // 补传只认 ticket：别的设备的工单不给追加视频。
    expect(
      find.byKey(const ValueKey<String>('feedback-detail-add-video')),
      findsNothing,
    );
  });

  testWidgets('处理台详情：视频给「播放视频」入口，不当截图解码', (WidgetTester tester) async {
    tallView(tester);
    server.details['devvidvid0'] = _detail(
      'devvidvid0',
      attachments: <Map<String, dynamic>>[
        _videoAttachment,
        <String, dynamic>{
          'slot': 'log',
          'kind': 'log',
          'bytes': 10,
          'type': 'application/gzip',
        },
      ],
    );
    final LeaderboardService b = await signedInBoard(tester);
    final FeedbackService f = feedback(b);
    await tester.pumpWidget(
      wrap(b, f, const FeedbackDevDetailPage(feedbackId: 'devvidvid0')),
    );
    final Finder play = find.byKey(
      const ValueKey<String>('feedback-dev-play-video'),
    );
    await settleIo(tester, () => play.evaluate().isNotEmpty);
    expect(play, findsOneWidget);
    expect(find.text(t.feedback_dev_screenshots), findsNothing);
    expect(
      server.requests.where(
        (http.Request r) => r.url.path.endsWith('/attachments/v0'),
      ),
      isEmpty,
    );
  });
}
