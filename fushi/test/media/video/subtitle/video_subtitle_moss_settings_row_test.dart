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

  @override
  Future<VideoSubtitleMossState> status(MossBackendPreference backend) async =>
      VideoSubtitleMossState(
        ready: disk > 0,
        totalBytes: 3000,
        obtainedBytes: disk,
      );

  @override
  Stream<ModelDownloadEvent> ensure(MossBackendPreference backend) =>
      const Stream<ModelDownloadEvent>.empty();

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
  Future<void> pump(WidgetTester tester, _Moss moss) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: VideoSubtitleMossSettingsRow(
              backend: MossBackendPreference.auto,
              port: moss,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

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
