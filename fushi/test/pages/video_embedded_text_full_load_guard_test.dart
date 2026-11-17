// 本地视频内封文本轨的整轨抽取（慢盘上一分钟以上，反馈 ZTDA2WQJj4）期间的播放页接线：
//  - 抽取期间先借播放器解码出字（桥），抽完换成完整列表；
//  - 不再用锁住整个字幕菜单的加载状态；用户可以停止读取、直接改选 / 关字幕；
//  - 慢的旧选择结束时按选择世代作废，不覆盖新选择；
//  - 下一集预热排在当前集读盘之后。
// 控制器侧的换装契约见 test/media/video/embedded_text_bridge_test.dart，引擎侧的排队见
// test/media/video/embedded_subtitle_disk_queue_test.dart；这里只钉页面接线（页面 State
// 起不了 libmpv，真 app 行为由 integration_test/video_embedded_text_subtitle_slow_extract_itest.dart 覆盖）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

String _bodyOf(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到 $signature');
  final int end = src.indexOf('\n  }\n', start);
  expect(end, greaterThan(start));
  return maskComments(src.substring(start, end));
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

  group('主字幕手选内封文本轨', () {
    late String body;
    setUp(() {
      body = _bodyOf(subtitlePart, '  Future<bool> _selectSubtitleSource(');
    });

    test('抽取开始时装桥，抽完换装完整列表', () {
      final int started = body.indexOf('onExtractionStarted:');
      final int bridge = body.indexOf('beginEmbeddedTextBridge(');
      final int complete = body.indexOf('completeEmbeddedTextBridge(');
      expect(started, isNonNegative);
      expect(bridge, greaterThan(started));
      expect(complete, greaterThan(bridge));
    });

    test('内封分支不再上锁菜单的加载状态（只有外挂分支还用）', () {
      final int embeddedLoad = body.indexOf('onExtractionStarted:');
      final int overlay = body.indexOf('_showSubtitleLoadingOverlay(');
      expect(
        overlay,
        greaterThan(embeddedLoad),
        reason: '加载遮罩只能出现在内封分支之后的外挂分支里',
      );
      expect('_showSubtitleLoadingOverlay('.allMatches(body).length, 1);
    });

    test('选择世代：每次选择 +1，结束时世代变了就作废', () {
      expect(body, contains('++_primarySubtitleSelectSeq'));
      expect(body, contains('selectSeq == _primarySubtitleSelectSeq'));
      final int seqCheck = body.indexOf('if (!stillChosen()) return false;');
      final int apply = body.indexOf('completeEmbeddedTextBridge(');
      expect(seqCheck, isNonNegative);
      expect(apply, greaterThan(seqCheck), reason: '先判世代再应用结果');
    });

    test('完整列表失败但桥在：保留播放器解码的字幕，不报「加载失败」', () {
      final int failure = body.indexOf('if (result.isFailure) {');
      final int live = body.indexOf('video_subtitle_full_load_failed_live');
      final int error = body.indexOf('_subtitleFailureMessage(failure');
      expect(live, greaterThan(failure));
      expect(error, greaterThan(live), reason: '有桥时先走保留分支');
    });
  });

  group('关字幕 / 删档 / 副字幕', () {
    test('关字幕与删档推进主字幕世代、撤下读取行', () {
      for (final String sig in <String>[
        '  Future<void> _selectSubtitleOff(',
        '  Future<void> _forgetDeletedSubtitleSelection(',
      ]) {
        final String body = _bodyOf(subtitlePart, sig);
        expect(body, contains('_primarySubtitleSelectSeq++'), reason: sig);
        expect(body, contains('_primaryEmbeddedFullLoad = null'), reason: sig);
      }
    });

    test('副字幕内封轨：不锁菜单、按世代作废、停止不当失败', () {
      final String body = _bodyOf(
        subtitlePart,
        '  Future<bool> _selectSecondarySubtitleSource(',
      );
      expect(body, contains('++_secondarySubtitleSelectSeq'));
      final int embeddedLoad = body.indexOf('onExtractionStarted:');
      final int overlay = body.indexOf('_showSubtitleLoadingOverlay(');
      expect(embeddedLoad, isNonNegative);
      expect(overlay, greaterThan(embeddedLoad));
      expect(body, contains('SubtitleCueLoadFailure.extractionCancelled'));
      final String off = _bodyOf(
        subtitlePart,
        '  Future<void> _selectSecondarySubtitleOff(',
      );
      expect(off, contains('_secondarySubtitleSelectSeq++'));
    });
  });

  group('停止读取', () {
    test('撤掉页面与播放器自动加载对这个视频的全部等待', () {
      final String body = _bodyOf(
        subtitlePart,
        '  void _cancelEmbeddedTextFullLoad() {',
      );
      expect(body, contains('_cancelEmbeddedSubtitleExtractFor(videoPath)'));
      expect(body, contains('cancelEmbeddedTextAutoLoadExtract()'));
    });

    test('读取行带停止按钮，挂在字幕分类顶部', () {
      final String rows = _bodyOf(
        subtitlePart,
        '  Widget _buildSubtitleTrackRows(',
      );
      expect(rows, contains('_embeddedTextFullLoadTile('));
      final String tile = _bodyOf(
        subtitlePart,
        '  Widget _embeddedTextFullLoadTile(',
      );
      expect(tile, contains('onPressed: _cancelEmbeddedTextFullLoad'));
    });

    test('换集撤掉旧视频的读取行与排队的预热记号', () {
      final String body = _bodyOf(
        subtitlePart,
        '  void _cancelEmbeddedSubtitleExtractFor(',
      );
      expect(body, contains('_lastPrewarmedEpisodePath = null'));
      final String all = _bodyOf(
        subtitlePart,
        '  void _cancelEmbeddedSubtitleExtracts(',
      );
      expect(all, contains('_primaryEmbeddedFullLoad = null'));
      expect(all, contains('_secondaryEmbeddedFullLoad = null'));
    });
  });

  group('自动加载与预热', () {
    test('控制器自动加载：抽取开始装桥并通知页面，期间换过源则作废', () {
      final String auto = _bodyOf(
        controller,
        '  Future<void> _loadEmbeddedSubtitleIfNeeded({',
      );
      expect(auto, contains('beginEmbeddedTextBridge('));
      expect(auto, contains('onEmbeddedSubtitleAutoLoadPending?.call('));
      expect(auto, contains('_cueSourceEpoch != sourceEpoch'));
      expect(auto, contains('completeEmbeddedTextBridge('));
    });

    test('页面接上自动加载的读取通知', () {
      expect(
        page,
        contains(
          'controller.onEmbeddedSubtitleAutoLoadPending =\n'
          '        _handleEmbeddedSubtitleAutoLoadPending;',
        ),
      );
    });

    test('下一集预热走后台排队', () {
      final String body = _bodyOf(
        page,
        '  void _prewarmNextEpisodeSubtitleCache() {',
      );
      expect(body, contains('background: true'));
    });
  });
}
