import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_model_ports.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_settings.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:material_ui/material_ui.dart';

class _Moss implements VideoSubtitleMossPort {
  _Moss(this.disk);

  int disk;
  int deletes = 0;

  /// 非 null 时 status 抛这个错误。
  String? statusFailure;

  @override
  Future<VideoSubtitleMossState> status(MossBackendPreference backend) async {
    final String? failure = statusFailure;
    if (failure != null) throw StateError(failure);
    return VideoSubtitleMossState(
      ready: disk > 0,
      totalBytes: 3000,
      obtainedBytes: disk,
    );
  }

  @override
  Stream<ModelDownloadEvent> ensure(MossBackendPreference backend) =>
      const Stream<ModelDownloadEvent>.empty();

  @override
  Stream<ModelDownloadEvent>? resumeEnsure() => null;

  @override
  Future<int> diskBytes() async => disk;

  @override
  Future<int> delete() async {
    deletes++;
    final int freed = disk;
    disk = 0;
    return freed;
  }
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    _Moss moss, {
    MossBackendPreference backend = MossBackendPreference.auto,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: VideoSubtitleMossSettingsRow(backend: backend, port: moss),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('读状态失败后再读成功：错误清掉、出现下载钮（不会一直停在错误上）', (WidgetTester tester) async {
    final _Moss moss = _Moss(0)..statusFailure = 'probe exploded';
    await pump(tester, moss);
    expect(find.textContaining('probe exploded'), findsOneWidget);
    final Finder download = find.byKey(
      const ValueKey<String>('video-subtitle-moss-files-download'),
    );
    expect(download, findsNothing);

    moss.statusFailure = null;
    await pump(tester, moss, backend: MossBackendPreference.cuda);
    expect(find.textContaining('probe exploded'), findsNothing);
    expect(
      find.text(
        t.video_subtitle_ai_moss_missing(size: FushiByteFormat.bytes(3000)),
      ),
      findsOneWidget,
    );
    expect(download, findsOneWidget);
  });

  testWidgets('盘上没有 MOSS 文件：不给删除', (WidgetTester tester) async {
    await pump(tester, _Moss(0));
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-moss-files-delete')),
      findsNothing,
    );
  });

  testWidgets('删除：确认框写清大小；取消不删，确认后删除并刷新为未下载', (WidgetTester tester) async {
    final _Moss moss = _Moss(2 * 1024 * 1024);
    await pump(tester, moss);
    final Finder delete = find.byKey(
      const ValueKey<String>('video-subtitle-moss-files-delete'),
    );
    expect(delete, findsOneWidget);

    await tester.tap(delete);
    await tester.pumpAndSettle();
    final String message = t.video_subtitle_ai_moss_delete_confirm(
      size: FushiByteFormat.bytes(2 * 1024 * 1024),
    );
    expect(find.text(message), findsOneWidget);
    await tester.tap(find.text(t.cancel).last);
    await tester.pumpAndSettle();
    expect(moss.deletes, 0);

    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_subtitle_ai_moss_delete).last);
    await tester.pumpAndSettle();
    expect(moss.deletes, 1);
    expect(delete, findsNothing);
    expect(
      find.text(
        t.video_subtitle_ai_moss_missing(size: FushiByteFormat.bytes(3000)),
      ),
      findsOneWidget,
    );
  });
}
