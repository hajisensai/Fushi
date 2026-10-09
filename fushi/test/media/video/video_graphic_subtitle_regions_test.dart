// 图形字幕「模糊」按位图本身糊：位图时间表的取用、外扩、序列化、请求推导，
// 以及遮蔽层只盖正在显示的句子（抽不出坐标时退回整条字幕带）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/pgs_subtitle_parser.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_obscure_layer.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_regions.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:material_ui/material_ui.dart';

const Size _canvas = Size(1920, 1080);

GraphicSubtitleRegionTrack _track() => GraphicSubtitleRegionTrack(
  canvas: _canvas,
  regions: const <GraphicSubtitleRegion>[
    // 故意乱序：构造时按起点排序。
    GraphicSubtitleRegion(
      startMs: 10000,
      endMs: 12000,
      rect: Rect.fromLTRB(600, 120, 1300, 200),
    ),
    GraphicSubtitleRegion(
      startMs: 4000,
      endMs: 7000,
      rect: Rect.fromLTRB(500, 900, 1420, 996),
    ),
  ],
);

class _FakeLoader implements GraphicSubtitleRegionLoader {
  _FakeLoader(this.result);

  final GraphicSubtitleRegionTrack? result;
  final List<GraphicSubtitleRegionRequest> requests =
      <GraphicSubtitleRegionRequest>[];

  @override
  Future<GraphicSubtitleRegionTrack?> load(
    GraphicSubtitleRegionRequest request, {
    required Size fallbackCanvas,
    Future<void>? cancel,
  }) async {
    requests.add(request);
    return result;
  }
}

VideoPlayerController _controller({required int positionMs}) {
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  c.debugSetGraphicSubtitleActiveForTesting(
    true,
    streamIndex: 0,
    codec: 'hdmv_pgs_subtitle',
  );
  c.debugSetIsPlayingForTesting(true);
  c.debugSetPositionForTesting(positionMs);
  return c;
}

const GraphicSubtitleRegionRequest _request = (
  videoPath: '/videos/ep03.mkv',
  streamIndex: 0,
);

void main() {
  group('GraphicSubtitleRegionTrack.blurRectsAt', () {
    test('句子显示期间给出外扩后的位图框，句间空隙什么都不给', () {
      final GraphicSubtitleRegionTrack t = _track();
      final List<Rect> during = t.blurRectsAt(5000);
      expect(during, hasLength(1));
      expect(
        during.single,
        graphicSubtitleBlurRect(
          const Rect.fromLTRB(500, 900, 1420, 996),
          _canvas,
        ),
      );
      expect(t.blurRectsAt(8500), isEmpty, reason: '句间没有字幕，画面不糊');
      expect(t.blurRectsAt(1000), isEmpty);
      expect(
        t.blurRectsAt(11000).single.top,
        lessThan(120),
        reason: '顶部字幕同样按位图',
      );
    });

    test('两头各放一点余量：起点前 / 终点后不足余量时仍糊', () {
      final GraphicSubtitleRegionTrack t = _track();
      expect(
        t.blurRectsAt(4000 - kGraphicSubtitleRegionLeadMs + 1),
        hasLength(1),
      );
      expect(t.blurRectsAt(4000 - kGraphicSubtitleRegionLeadMs - 1), isEmpty);
      expect(
        t.blurRectsAt(7000 + kGraphicSubtitleRegionTailMs - 1),
        hasLength(1),
      );
      expect(t.blurRectsAt(7000 + kGraphicSubtitleRegionTailMs + 1), isEmpty);
    });

    test('长轨上二分查找与线性扫描结论一致', () {
      final List<GraphicSubtitleRegion> regions = <GraphicSubtitleRegion>[
        for (int i = 0; i < 500; i++)
          GraphicSubtitleRegion(
            startMs: i * 3000,
            endMs: i * 3000 + 1800 + (i % 7) * 100,
            rect: Rect.fromLTWH(400, 900, 800 + (i % 5) * 10, 80),
          ),
      ];
      final GraphicSubtitleRegionTrack t = GraphicSubtitleRegionTrack(
        canvas: _canvas,
        regions: regions,
      );
      for (int pos = 0; pos < 1500000; pos += 977) {
        final int expected = regions
            .where(
              (GraphicSubtitleRegion r) =>
                  r.startMs - kGraphicSubtitleRegionLeadMs <= pos &&
                  r.endMs + kGraphicSubtitleRegionTailMs > pos,
            )
            .length;
        expect(t.blurRectsAt(pos), hasLength(expected), reason: 'pos=$pos');
      }
    });
  });

  test('外扩：按位图高度放大一圈，夹在画布内', () {
    final Rect r = graphicSubtitleBlurRect(
      const Rect.fromLTRB(500, 1000, 1420, 1076),
      _canvas,
    );
    expect(r.left, lessThan(500));
    expect(r.top, lessThan(1000));
    expect(r.bottom, 1080, reason: '不出画布');
    // 外扩只是一圈，不是整条带：宽度远小于画面。
    expect(r.width, lessThan(_canvas.width * 0.6));
  });

  test('JSON 往返；损坏的缓存当没有', () {
    final GraphicSubtitleRegionTrack t = _track();
    final GraphicSubtitleRegionTrack? back =
        GraphicSubtitleRegionTrack.fromJson(t.toJson());
    expect(back, isNotNull);
    expect(back!.canvas, _canvas);
    expect(back.regions.map((GraphicSubtitleRegion r) => r.startMs), <int>[
      4000,
      10000,
    ]);
    expect(back.regions.first.rect, const Rect.fromLTRB(500, 900, 1420, 996));
    expect(GraphicSubtitleRegionTrack.fromJson('x'), isNull);
    expect(
      GraphicSubtitleRegionTrack.fromJson(<String, Object?>{
        'w': 1920,
        'h': 1080,
        'r': <Object?>[
          <Object?>[1, 2, 'a', 4, 5, 6],
        ],
      }),
      isNull,
    );
  });

  test('PGS cue → 时间表：用 PCS 声明的画布，空对象跳过', () {
    final GraphicSubtitleRegionTrack t = graphicSubtitleRegionsFromPgs(
      PgsSubtitleParser.parse(_oneCueSup(canvasW: 1280, canvasH: 720)),
      fallbackCanvas: _canvas,
    );
    expect(t.canvas, const Size(1280, 720));
    expect(t.regions, hasLength(1));
    expect(t.regions.single.startMs, 1000);
    expect(t.regions.single.endMs, 3000);
    expect(t.regions.single.rect, const Rect.fromLTRB(100, 200, 104, 202));
  });

  group('graphicSubtitleRegionRequestFor', () {
    const ({int streamIndex, String? codec}) pgs = (
      streamIndex: 2,
      codec: 'hdmv_pgs_subtitle',
    );
    test('本地 PGS 轨才按位图糊', () {
      expect(
        graphicSubtitleRegionRequestFor(videoPath: '/v/a.mkv', track: pgs),
        (videoPath: '/v/a.mkv', streamIndex: 2),
      );
      expect(
        graphicSubtitleRegionRequestFor(
          videoPath: r'C:\videos\a.m2ts',
          track: pgs,
        ),
        isNotNull,
        reason: 'Windows 盘符不是 URL scheme',
      );
    });
    test('远端流 / VobSub / DVB / 没有图形轨 → 退回整条字幕带', () {
      expect(
        graphicSubtitleRegionRequestFor(
          videoPath: 'http://192.168.1.2/a.mkv',
          track: pgs,
        ),
        isNull,
      );
      expect(
        graphicSubtitleRegionRequestFor(
          videoPath: '/v/a.mkv',
          track: (streamIndex: 0, codec: 'dvd_subtitle'),
        ),
        isNull,
      );
      expect(
        graphicSubtitleRegionRequestFor(videoPath: '/v/a.mkv', track: null),
        isNull,
      );
      expect(
        graphicSubtitleRegionRequestFor(videoPath: null, track: pgs),
        isNull,
      );
    });
  });

  test('控制器只在图形模式下报当前图形轨', () {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.debugSetGraphicSubtitleActiveForTesting(
      true,
      streamIndex: 1,
      codec: 'hdmv_pgs_subtitle',
    );
    expect(c.activeGraphicSubtitleTrack, (
      streamIndex: 1,
      codec: 'hdmv_pgs_subtitle',
    ));
    c.debugSetGraphicSubtitleActiveForTesting(false, streamIndex: 1);
    expect(c.activeGraphicSubtitleTrack, isNull);
  });

  group('遮蔽层按位图糊', () {
    Future<void> pump(
      WidgetTester tester,
      VideoPlayerController c,
      GraphicSubtitleRegionLoader loader,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 540);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoGraphicSubtitleObscureLayer(
              controller: c,
              fit: BoxFit.contain,
              obscure: GraphicSubtitleObscure.blur,
              revealOnInteraction: true,
              lookupPopupVisible: false,
              regionRequest: _request,
              regionLoader: loader,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Finder blur() =>
        find.byKey(const ValueKey<String>('graphic_subtitle_obscure_blur'));
    Finder region() =>
        find.byKey(const ValueKey<String>('graphic_subtitle_obscure_region_0'));
    Finder band() =>
        find.byKey(const ValueKey<String>('graphic_subtitle_obscure_band'));

    testWidgets('句子显示中：只糊位图那一块，不是整条字幕带', (WidgetTester tester) async {
      final VideoPlayerController c = _controller(positionMs: 5000);
      addTearDown(c.dispose);
      final _FakeLoader loader = _FakeLoader(_track());
      await pump(tester, c, loader);
      expect(loader.requests, <GraphicSubtitleRegionRequest>[_request]);
      expect(band(), findsNothing);
      expect(region(), findsOneWidget);
      expect(blur(), findsOneWidget);
      // 960x540 视图里 1920x1080 画面按 0.5 缩放：外扩后的位图框映射过来。
      final Rect expected = graphicSubtitleBlurRect(
        const Rect.fromLTRB(500, 900, 1420, 996),
        _canvas,
      );
      final Rect got = tester.getRect(region());
      expect(got.left, closeTo(expected.left / 2, 0.5));
      expect(got.top, closeTo(expected.top / 2, 0.5));
      expect(got.right, closeTo(expected.right / 2, 0.5));
      expect(got.bottom, closeTo(expected.bottom / 2, 0.5));
      expect(got.width, lessThan(960 * 0.6), reason: '不糊整条带');
    });

    testWidgets('句间空隙：画面完全不糊；播放推进到下一句又糊上', (WidgetTester tester) async {
      final VideoPlayerController c = _controller(positionMs: 8500);
      addTearDown(c.dispose);
      await pump(tester, c, _FakeLoader(_track()));
      expect(blur(), findsNothing);
      expect(band(), findsNothing);

      c.debugSetPositionForTesting(11000);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(region(), findsOneWidget);
      expect(tester.getRect(region()).top, lessThan(60), reason: '顶部那句');
    });

    testWidgets('拿不到坐标（抽不出 / VobSub）时退回整条字幕带', (WidgetTester tester) async {
      final VideoPlayerController c = _controller(positionMs: 5000);
      addTearDown(c.dispose);
      await pump(tester, c, _FakeLoader(null));
      expect(region(), findsNothing);
      expect(band(), findsOneWidget);
      expect(blur(), findsOneWidget);
    });

    testWidgets('暂停 = 用户在看：位图框也让位', (WidgetTester tester) async {
      final VideoPlayerController c = _controller(positionMs: 5000);
      addTearDown(c.dispose);
      await pump(tester, c, _FakeLoader(_track()));
      expect(blur(), findsOneWidget);
      c.debugSetIsPlayingForTesting(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(blur(), findsNothing);
    });
  });
}

/// 一条 1s→3s 的 PGS cue（4x2 对象落在 (100, 200)），PCS 声明 [canvasW]x[canvasH]。
Uint8List _oneCueSup({required int canvasW, required int canvasH}) {
  List<int> u16(int v) => <int>[(v >> 8) & 0xFF, v & 0xFF];
  final List<int> rle = <int>[
    0x00, 0x84, 0x01, 0x00, 0x00, //
    0x00, 0x84, 0x01, 0x00, 0x00,
  ];
  List<int> pcs(bool show, bool epoch) => <int>[
    ...u16(canvasW),
    ...u16(canvasH),
    0x10,
    ...u16(0),
    epoch ? 0x80 : 0x00,
    0x00,
    0x00,
    if (show) ...<int>[1, ...u16(0), 0x00, 0x00, ...u16(100), ...u16(200)] else
      0,
  ];
  final List<(int, List<(int, List<int>)>)> sets =
      <(int, List<(int, List<int>)>)>[
        (
          90000,
          <(int, List<int>)>[
            (0x16, pcs(true, true)),
            (0x14, <int>[0x00, 0x00, 0x01, 235, 128, 128, 0xFF]),
            (
              0x15,
              <int>[
                ...u16(0),
                0x00,
                0xC0,
                0x00,
                ...u16(rle.length + 4),
                ...u16(4),
                ...u16(2),
                ...rle,
              ],
            ),
            (0x80, <int>[]),
          ],
        ),
        (
          270000,
          <(int, List<int>)>[(0x16, pcs(false, false)), (0x80, <int>[])],
        ),
      ];
  final BytesBuilder out = BytesBuilder();
  for (final (int pts, List<(int, List<int>)> segments) in sets) {
    for (final (int type, List<int> body) in segments) {
      out
        ..add(<int>[0x50, 0x47])
        ..add(<int>[
          (pts >> 24) & 0xFF,
          (pts >> 16) & 0xFF,
          (pts >> 8) & 0xFF,
          pts & 0xFF,
        ])
        ..add(<int>[0, 0, 0, 0])
        ..add(<int>[type, ...u16(body.length)])
        ..add(body);
    }
  }
  return out.toBytes();
}
