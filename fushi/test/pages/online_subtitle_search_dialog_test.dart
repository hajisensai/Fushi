import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/online_subtitle_search_dialog.dart';

/// 在线字幕对话框（provider 无关）：OpenSubtitles 等只有标题/哈希两种检索键的源，此前
/// 只在发现页/下载流水线可达，播放页完全没有入口。本对话框补上那条路，并与 Jimaku 专用
/// 对话框共用同一个 pop 契约（返回下载好的本地绝对路径），播放页落地逻辑因此只需一份。
class _StubCandidate extends VideoSubtitleCandidate {
  _StubCandidate({
    required super.providerId,
    required super.fileName,
    super.remoteId = 'r1',
    super.language = 'ja',
    super.providerPriority = 200,
    super.episode,
  });
}

class _StubProvider implements VideoSubtitleProvider {
  _StubProvider({required this.id, required this.downloadFileName});

  @override
  final String id;

  final String downloadFileName;

  /// 落盘内容的固定探针字节，用于断言「写下去的就是 provider 给的那份」。
  static const List<int> bytes = <int>[1, 2, 3];

  int downloadCalls = 0;

  @override
  int get priority => 200;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoSubtitleCandidate>.success(
          const <VideoSubtitleCandidate>[]);

  @override
  Future<VideoSubtitleDownload> download(
      VideoSubtitleCandidate candidate) async {
    downloadCalls++;
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(bytes),
      fileName: downloadFileName,
      language: candidate.language,
    );
  }

  @override
  void close() {}
}

void main() {
  late Directory saveDir;

  /// 对话框 pop 出来的值。必须是外层变量而不是 `pumpDialog` 的返回值——pop 发生在点击
  /// 之后，按值返回只会拿到点击前的 null 快照。
  String? popped;

  setUp(() {
    saveDir = Directory.systemTemp.createTempSync('online_subs_test');
    popped = null;
  });

  tearDown(() {
    try {
      if (saveDir.existsSync()) saveDir.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录清理失败不该盖掉真正的断言失败（Windows 上句柄释放有延迟）。
    }
  });

  /// 点一条候选并等真实落盘完成。
  ///
  /// 下载路径里有真实文件 IO，而 widget test 默认跑在 FakeAsync 区域——`pumpAndSettle`
  /// 推不动真实事件循环，`File.writeAsBytes` 的 Future 永远不完成。必须在 [runAsync]
  /// 里驱动，否则一定超时。
  Future<void> tapAndSettleIo(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      for (int i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (find.byType(OnlineSubtitleSearchDialog).evaluate().isEmpty) break;
      }
    });
    await tester.pump();
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    required VideoSubtitleRegistry registry,
    required ProviderBatchResult<VideoSubtitleCandidate> seed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (BuildContext ctx) {
            return ElevatedButton(
              onPressed: () async {
                popped = await showDialog<String>(
                  context: ctx,
                  builder: (_) => OnlineSubtitleSearchDialog(
                    registry: registry,
                    initialQuery: '最愛',
                    saveDirectory: saveDir.path,
                    debugInitialResult: seed,
                  ),
                );
              },
              child: const Text('open'),
            );
          }),
        ),
      ),
    );
    await tester.tap(find.text('open'), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  testWidgets('候选按「文件名 + 来源·语言」渲染', (WidgetTester tester) async {
    final _StubProvider provider = _StubProvider(
      id: 'opensubtitles',
      downloadFileName: 'saiai.ja.srt',
    );
    await pumpDialog(
      tester,
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      seed: ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _StubCandidate(
            providerId: 'opensubtitles',
            fileName: 'saiai.ja.srt',
            episode: 1,
          ),
        ],
      ),
    );

    expect(find.text('saiai.ja.srt'), findsOneWidget);
    // 来源必须可见：同一列表里混着多个源的结果，看不出出处就没法判断可信度。
    expect(find.textContaining('opensubtitles'), findsOneWidget);
  });

  testWidgets('点候选 → 下载落盘并 pop 回本地路径', (WidgetTester tester) async {
    final _StubProvider provider = _StubProvider(
      id: 'opensubtitles',
      downloadFileName: 'saiai.ja.srt',
    );
    await pumpDialog(
      tester,
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      seed: ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _StubCandidate(
            providerId: 'opensubtitles',
            fileName: 'saiai.ja.srt',
          ),
        ],
      ),
    );

    await tapAndSettleIo(tester, 'saiai.ja.srt');

    expect(provider.downloadCalls, 1);
    final File written = File(p.join(saveDir.path, 'saiai.ja.srt'));
    expect(written.existsSync(), isTrue);
    expect(written.readAsBytesSync(), <int>[1, 2, 3]);
    // pop 契约与 Jimaku 对话框一致：返回本地绝对路径，播放页据此走同一条落地路径。
    expect(popped, written.path);
  });

  testWidgets('远端文件名带路径分隔符时只取 basename（不逃出保存目录）', (WidgetTester tester) async {
    final _StubProvider provider = _StubProvider(
      id: 'opensubtitles',
      downloadFileName: '../../evil.srt',
    );
    await pumpDialog(
      tester,
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      seed: ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _StubCandidate(providerId: 'opensubtitles', fileName: 'shown.srt'),
        ],
      ),
    );

    await tapAndSettleIo(tester, 'shown.srt');

    expect(File(p.join(saveDir.path, 'evil.srt')).existsSync(), isTrue);
    expect(
      File(p.join(saveDir.parent.path, 'evil.srt')).existsSync(),
      isFalse,
      reason: '文件名来自远端，绝不能带着 ../ 写到保存目录之外',
    );
  });

  testWidgets('零结果时把 provider 失败原因单独显示出来', (WidgetTester tester) async {
    final _StubProvider provider = _StubProvider(
      id: 'opensubtitles',
      downloadFileName: 'x.srt',
    );
    await pumpDialog(
      tester,
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      seed: ProviderBatchResult<VideoSubtitleCandidate>.failure(
        const ExternalProviderFailure(
          providerId: 'opensubtitles',
          operation: 'search',
          kind: ExternalProviderFailureKind.unauthorized,
          message: 'OpenSubtitles API key is not configured',
        ),
      ),
    );

    // 「源挂了」和「真没有字幕」是两件事，混成一句「没找到」会让用户白等下去。
    expect(
      find.textContaining('OpenSubtitles API key is not configured'),
      findsOneWidget,
    );
  });
}
