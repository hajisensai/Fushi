import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart'
    show audiobookTitleForAudioPaths;
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi/src/media/audiobook/audiobook_auto_transcribe.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';

class _Calls {
  final List<DiscoveryImportPlan> imported = <DiscoveryImportPlan>[];
  final List<String> enqueued = <String>[];
}

Future<DiscoveryImportOutcome> _route(
  TranscribeAudiobookPlan plan, {
  required bool enabled,
  AudiobookMaterialMatch match = const AudiobookMaterialMatch(),
  Set<String> contentInLibrary = const <String>{},
  required _Calls calls,
}) => routeTranscribeAudiobookPlan(
  plan,
  autoTranscribeEnabled: enabled,
  contentAlreadyInLibrary: (String path) async =>
      contentInLibrary.contains(path),
  matchMaterials: (List<String> audio, String title) async => match,
  importNow: (DiscoveryImportPlan p) async {
    calls.imported.add(p);
    return 'key';
  },
  enqueue:
      ({
        required List<String> audioPaths,
        String? contentPath,
        required String title,
      }) async {
        calls.enqueued.add('$title|$contentPath|${audioPaths.join(',')}');
        return AudiobookTranscribeJob(
          id: '1',
          title: title,
          audioPaths: audioPaths,
          contentPath: contentPath,
          createdAt: 0,
          updatedAt: 0,
        );
      },
);

void main() {
  group('audiobookTitleForAudioPaths', () {
    test('单文件取文件名,去掉末尾 [ASIN]', () {
      expect(
        audiobookTitleForAudioPaths(<String>[
          r'D:\dl\リアデイルの大地にて 1 [B07L3PTYY6].m4b',
        ]),
        'リアデイルの大地にて 1',
      );
      expect(audiobookTitleForAudioPaths(<String>['/x/book.mp3']), 'book');
    });

    test('多文件取最近公共祖先目录名;没有公共目录时退回第一份的文件名', () {
      expect(
        audiobookTitleForAudioPaths(<String>[
          '/dl/銀河鉄道の夜/01.mp3',
          '/dl/銀河鉄道の夜/02.mp3',
        ]),
        '銀河鉄道の夜',
      );
      // 多碟:书名/CD1、书名/CD2——不能叫成「CD1」或「01」(两本多碟书会被同名
      // 查重互相挤掉)。
      expect(
        audiobookTitleForAudioPaths(<String>[
          r'D:\dl\銀河鉄道の夜\CD1\01.mp3',
          r'D:\dl\銀河鉄道の夜\CD2\01.mp3',
        ]),
        '銀河鉄道の夜',
      );
      expect(
        audiobookTitleForAudioPaths(<String>['/a/01.mp3', '/b/02.mp3']),
        '01',
      );
      expect(
        audiobookTitleForAudioPaths(<String>[r'D:\01.mp3', r'E:\02.mp3']),
        '01',
      );
    });

    test('名字只有 [ASIN] 时不剥成空串', () {
      expect(
        audiobookTitleForAudioPaths(<String>['/x/[B07L3PTYY6].m4b']),
        '[B07L3PTYY6]',
      );
    });
  });

  group('routeTranscribeAudiobookPlan', () {
    const TranscribeAudiobookPlan audioOnly = TranscribeAudiobookPlan(
      audioPaths: <String>['/dl/Book/01.mp3', '/dl/Book/02.mp3'],
    );

    test('开关开、素材库配不到 → 排转录,结果 deferred', () async {
      final _Calls calls = _Calls();
      final DiscoveryImportOutcome outcome = await _route(
        audioOnly,
        enabled: true,
        calls: calls,
      );
      expect(outcome.deferred, isTrue);
      expect(outcome.importedCount, 0);
      expect(outcome.summary, 'Book');
      expect(calls.enqueued, <String>[
        'Book|null|/dl/Book/01.mp3,/dl/Book/02.mp3',
      ]);
      expect(calls.imported, isEmpty);
    });

    test('开关关(或无 ASR)且配不到 → 与改前同一原因码挡下', () async {
      final _Calls calls = _Calls();
      await expectLater(
        _route(audioOnly, enabled: false, calls: calls),
        throwsA(
          isA<DiscoveryImportBlockedException>().having(
            (DiscoveryImportBlockedException e) => e.blocker,
            'blocker',
            DiscoveryImportBlocker.audiobookMissingSubtitle,
          ),
        ),
      );
      expect(calls.enqueued, isEmpty);
    });

    test('素材库身份键命中字幕 → 立刻入库,不跑转录(开关关也一样)', () async {
      for (final bool enabled in <bool>[true, false]) {
        final _Calls calls = _Calls();
        final DiscoveryImportOutcome outcome = await _route(
          audioOnly,
          enabled: enabled,
          match: const AudiobookMaterialMatch(subtitlePath: '/m/b.srt'),
          calls: calls,
        );
        expect(outcome.importedCount, 1);
        expect(outcome.deferred, isFalse);
        expect(calls.enqueued, isEmpty);
        final SubtitleAudiobookPlan plan =
            calls.imported.single as SubtitleAudiobookPlan;
        expect(plan.subtitlePath, '/m/b.srt');
      }
    });

    test('素材库字幕 + 正文都命中 → 对齐导入', () async {
      final _Calls calls = _Calls();
      await _route(
        audioOnly,
        enabled: true,
        match: const AudiobookMaterialMatch(
          subtitlePath: '/m/b.srt',
          contentPath: '/m/b.epub',
        ),
        calls: calls,
      );
      final AlignAudiobookPlan plan =
          calls.imported.single as AlignAudiobookPlan;
      expect(plan.contentPath, '/m/b.epub');
      expect(plan.subtitlePath, '/m/b.srt');
    });

    test('标题猜出来的弱匹配不进后台自动链路', () async {
      final _Calls calls = _Calls();
      await _route(
        audioOnly,
        enabled: true,
        match: const AudiobookMaterialMatch(
          subtitlePath: '/m/guess.srt',
          subtitleIsWeakMatch: true,
          contentPath: '/m/guess.epub',
          contentIsWeakMatch: true,
        ),
        calls: calls,
      );
      expect(calls.imported, isEmpty);
      expect(calls.enqueued.single, startsWith('Book|null|'));
    });

    test('素材库只配到正文(身份键) → 带着正文去转录,转完对齐', () async {
      final _Calls calls = _Calls();
      await _route(
        audioOnly,
        enabled: true,
        match: const AudiobookMaterialMatch(contentPath: '/m/b.epub'),
        calls: calls,
      );
      expect(calls.enqueued.single, startsWith('Book|/m/b.epub|'));
    });

    test('正文已在库 → 入队前就挡下(同齐料包的原因码),不白跑转录', () async {
      for (final AudiobookMaterialMatch match in <AudiobookMaterialMatch>[
        const AudiobookMaterialMatch(),
        const AudiobookMaterialMatch(subtitlePath: '/m/b.srt'),
      ]) {
        final _Calls calls = _Calls();
        await expectLater(
          _route(
            const TranscribeAudiobookPlan(
              audioPaths: <String>['/dl/Book/01.mp3'],
              contentPath: '/dl/Book/book.epub',
            ),
            enabled: true,
            match: match,
            contentInLibrary: const <String>{'/dl/Book/book.epub'},
            calls: calls,
          ),
          throwsA(
            isA<DiscoveryImportBlockedException>()
                .having(
                  (DiscoveryImportBlockedException e) => e.blocker,
                  'blocker',
                  DiscoveryImportBlocker.audiobookBookAlreadyInLibrary,
                )
                .having(
                  (DiscoveryImportBlockedException e) => e.detail,
                  'detail',
                  'book.epub',
                ),
          ),
        );
        expect(calls.enqueued, isEmpty);
        expect(calls.imported, isEmpty);
      }
    });

    test('包里自带正文优先于素材库', () async {
      final _Calls calls = _Calls();
      await _route(
        const TranscribeAudiobookPlan(
          audioPaths: <String>['/dl/Book/01.mp3'],
          contentPath: '/dl/Book/book.epub',
        ),
        enabled: true,
        match: const AudiobookMaterialMatch(contentPath: '/m/other.epub'),
        calls: calls,
      );
      expect(calls.enqueued.single, startsWith('01|/dl/Book/book.epub|'));
    });
  });
}
