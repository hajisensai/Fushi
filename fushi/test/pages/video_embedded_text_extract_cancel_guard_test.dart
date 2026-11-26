// BUG-4838：内封文本字幕整轨抽取要读完整个容器，慢盘上可以跑几分钟。退页 / 换集后
// 不能让它在后台继续把旧文件读完——取消信号必须接到播放页与播放器的生命周期上
// （与图形字幕整轨抽取 `_cancelGraphicSubtitleOcr` / `_cancelGraphicTimingFetch` 同一机制）。
import 'dart:io';

import 'package:test/test.dart';

String _bodyOf(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到 $signature');
  final int end = src.indexOf('\n  }\n', start);
  expect(end, greaterThan(start));
  return src.substring(start, end);
}

void main() {
  final String page = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync();
  final String subtitlePart = File(
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
  ).readAsStringSync();
  final String controller = File(
    'lib/src/media/video/video_player_controller.dart',
  ).readAsStringSync();

  group('播放页', () {
    test('换了视频源时撤掉旧视频的抽取（保留新当前集那份）', () {
      expect(
        page.contains(
          'if (clipExportSourceChanged) _cancelEmbeddedSubtitleExtracts(videoPath);',
        ),
        isTrue,
      );
    });

    test('退页时全撤', () {
      final String dispose = _bodyOf(page, '  void dispose() {');
      expect(dispose, contains('_cancelEmbeddedSubtitleExtracts();'));
    });

    test('预热（当前集 + 下一集）、主 / 副字幕切换、恢复路径都带取消信号', () {
      final int prewarms = RegExp(
        r'prewarmEmbeddedSubtitleCache\(\s*\w+,\s*cancel: _embeddedSubtitleExtractCancelFor\(',
      ).allMatches(page).length;
      expect(prewarms, 2, reason: '当前集预热 + 下一集预热');
      final int switches = RegExp(
        r'loadSubtitleCueResult\(\s*source,\s*videoPath,\s*bookUid,\s*cancel: _embeddedSubtitleExtractCancelFor\(videoPath\)',
      ).allMatches(subtitlePart).length;
      expect(switches, 2, reason: '主字幕与副字幕两条选择路径');
      // 恢复路径两处解析都经载入链 helper；helper 的内嵌分支带取消信号（外挂档
      // 只读一个文件，无需取消）。
      // 恢复本行选择（导入字幕捷径 + 精确匹配的源）与沿用兄弟集选择共用
      // _loadChosenSubtitleForLoad 加载选定的源（BUG-5464）。
      final String restore = _bodyOf(page, '  _restorePersistedSubtitle({');
      final String chosen = _bodyOf(
        page,
        '  _loadChosenSubtitleForLoad(SubtitleSource chosen',
      );
      expect('_loadCuesForSourceInLoad('.allMatches(restore).length, 1);
      expect('_loadChosenSubtitleForLoad('.allMatches(restore).length, 1);
      expect('_loadCuesForSourceInLoad('.allMatches(chosen).length, 1);
      final String inherit = _bodyOf(page, '  _restoreInheritedSubtitle({');
      expect('_loadChosenSubtitleForLoad('.allMatches(inherit).length, 1);
      for (final String body in <String>[restore, chosen, inherit]) {
        expect(body, isNot(contains('loadCuesForSource(')));
      }
      final String inLoad = _bodyOf(
        page,
        '  Future<List<AudioCue>> _loadCuesForSourceInLoad(',
      );
      expect(
        inLoad,
        contains('cancel: _embeddedSubtitleExtractCancelFor(videoPath)'),
      );
    });

    test('撤销时完成 Completer 并从表里移除', () {
      final String cancelAll = _bodyOf(
        subtitlePart,
        'void _cancelEmbeddedSubtitleExtracts(',
      );
      expect(cancelAll, contains('_cancelEmbeddedSubtitleExtractFor(path)'));
      final String cancel = _bodyOf(
        subtitlePart,
        'void _cancelEmbeddedSubtitleExtractFor(',
      );
      expect(cancel, contains('cancel.complete()'));
      expect(cancel, contains('_embeddedSubtitleExtractCancels.remove('));
    });
  });

  group('播放器控制器', () {
    test('每次 load 轮换取消信号（换片撤掉上一片的自动抽取）', () {
      final int loadAt = controller.indexOf('  Future<void> load({');
      expect(loadAt, isNonNegative);
      // 参数表很长：窗口取到 load 开头那段换片复位（`_audioOutputRecovery.reset()`）。
      final int resetAt = controller.indexOf(
        '_audioOutputRecovery.reset();',
        loadAt,
      );
      expect(resetAt, greaterThan(loadAt));
      final String head = controller.substring(loadAt, resetAt);
      expect(head, contains('_cancelEmbeddedTextExtract();'));
      expect(head, contains('_embeddedTextExtractCancel = Completer<void>();'));
    });

    test('dispose 与释放媒体句柄都撤销', () {
      final String dispose = _bodyOf(controller, '  void dispose() {');
      expect(dispose, contains('_cancelEmbeddedTextExtract();'));
      final String release = _bodyOf(
        controller,
        '  Future<void> _releaseMediaHandles() async {',
      );
      expect(release, contains('_cancelEmbeddedTextExtract();'));
    });

    test('自动抽取把取消信号交给加载协调器', () {
      final String auto = _bodyOf(
        controller,
        '  Future<void> _loadEmbeddedSubtitleIfNeeded({',
      );
      expect(auto, contains('cancel: _embeddedTextExtractCancel?.future'));
      expect(
        auto.contains('parsed 0 cues'),
        isFalse,
        reason: '日志按真实失败原因写，不再一律说「解析出 0 条」',
      );
      expect(auto, contains('result.cueFailure?.name'));
    });
  });
}
