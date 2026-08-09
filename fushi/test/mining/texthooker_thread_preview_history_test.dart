import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

/// BUG-1474 守卫：线程选择弹窗每条线程要能看到最近 2~3 句，不是一句。
///
/// native 线程预览区是**全量快照、每线程恒一条**（见 `applyTextThreadPreviews`
/// 的注释），所以多句只能由 Dart 侧跨轮询累积。选择弹窗那行早就写着
/// `maxLines: 3` —— 缺的一直是数据不是 UI。
///
/// 用户诉求的由来：一句话经常是「……」或一个人名，根本分辨不出这条线程是不是
/// 正文流；而选错线程 = 整个功能不可用。
void main() {
  TexthookerThreadPreview preview(
    int id,
    String text, {
    int observedLineCount = 1,
  }) =>
      TexthookerThreadPreview(
        nativeThreadId: id,
        text: text,
        observedLineCount: observedLineCount,
        observedArtifactCount: 0,
        isArtifact: false,
      );

  TexthookerService seeded() {
    final TexthookerService service = TexthookerService.test();
    service.registerTextThread(
      key: 'luna:5',
      label: 'EmbedKrkrZ · 0x459f50',
      nativeThreadId: 5,
    );
    return service;
  }

  List<String> historyOf(TexthookerService service) =>
      service.textThreads.single.recentPreviewTexts;

  test('跨轮询累积：三轮不同预览 ⇒ 最近 3 句，新的在前', () {
    final TexthookerService service = seeded();
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '一句目です。'),
    ]);
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '二句目です。', observedLineCount: 2),
    ]);
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '三句目です。', observedLineCount: 3),
    ]);
    expect(historyOf(service), <String>['三句目です。', '二句目です。', '一句目です。']);
  });

  test('环上限 3：第四句把最旧那句挤掉', () {
    final TexthookerService service = seeded();
    for (int i = 1; i <= 4; i++) {
      service.applyTextThreadPreviews(<TexthookerThreadPreview>[
        preview(5, '$i句目', observedLineCount: i),
      ]);
    }
    expect(historyOf(service), <String>['4句目', '3句目', '2句目']);
    expect(historyOf(service).length, kTexthookerPreviewHistory);
  });

  test('同一句在多轮快照里重复出现时不重复入环（逐字重绘引擎的常态）', () {
    final TexthookerService service = seeded();
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '同じ台詞'),
    ]);
    // 文本没变、只有观测计数在涨：这在 KiriKiriZ 这类引擎上每轮都发生。
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '同じ台詞', observedLineCount: 2),
    ]);
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '同じ台詞', observedLineCount: 3),
    ]);
    expect(historyOf(service), <String>['同じ台詞']);
  });

  test('线程从快照里消失 ⇒ 它的历史一并走，不留旧句在列表里', () {
    final TexthookerService service = seeded();
    service.registerTextThread(
      key: 'luna:9',
      label: 'TextRender · 0x1234',
      nativeThreadId: 9,
    );
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '本文スレッド'),
      preview(9, 'メニュー'),
    ]);
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '本文スレッド2', observedLineCount: 2),
    ]);
    final Map<String, List<String>> byKey = <String, List<String>>{
      for (final TexthookerTextThread t in service.textThreads)
        t.key: t.recentPreviewTexts,
    };
    expect(byKey['luna:5'], <String>['本文スレッド2', '本文スレッド']);
    expect(byKey['luna:9'], isEmpty);
  });

  test('clearTextThreadPreviews 把历史一起清干净', () {
    final TexthookerService service = seeded();
    service.applyTextThreadPreviews(<TexthookerThreadPreview>[
      preview(5, '一句目'),
    ]);
    expect(historyOf(service), isNotEmpty);
    service.clearTextThreadPreviews();
    expect(historyOf(service), isEmpty);
  });

  group('texthookerThreadSubtitle', () {
    test('有多句时一句一行地展示，取代单句', () {
      final String? subtitle = texthookerThreadSubtitle(
        audioLineCount: 0,
        latestText: '古い一句だけ',
        recentTexts: const <String>['三句目', '二句目', '一句目'],
        audioLabel: 'audio',
      );
      expect(subtitle, '三句目\n二句目\n一句目');
    });

    test('没有多句时逐字回退到旧行为（既有调用点不受影响）', () {
      expect(
        texthookerThreadSubtitle(
          audioLineCount: 2,
          latestText: '唯一の一句',
          audioLabel: '2 行有音频',
        ),
        '2 行有音频 · 唯一の一句',
      );
    });
  });
}
