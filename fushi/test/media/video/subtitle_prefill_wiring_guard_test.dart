import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-2626 源码扫描守卫：播放页把**番名**与**集号**填进字幕检索请求的那两处接线。
///
/// 三块拼图各有自己的测试——选词规则（`subtitle_search_seed_test.dart` 的
/// `remoteSubtitleSeriesQuery`）、集号来源（`anime_source_video_client_test.dart` 的
/// `remoteVideoEpisodeNumber`）、输入框预填（`subtitle_workbench_page_test.dart`）。
/// 只有把它们接起来的 `_jimakuQuery` / `_openSubtitleWorkbench` 是页面 State 的私有
/// 方法（`part of video_fushi_page.dart`），没有可注入的缝；源码扫描是这一段能落地的
/// 最强层，与 `remote_mining_image_mode_test.dart` 的 imageMode 守卫同形。
///
/// 三块都对而接线断掉时，用户看到的就是原样的故障：番名框里写着 `Episode 1`、集数框空。
void main() {
  final String src = File(
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
  ).readAsStringSync();
  // 剥注释再扫：散文里为解释这条链必然写出同样的符号名，让文档把守卫喂绿是假阳性。
  final String code = maskComments(src);

  group('字幕检索预填接线（BUG-2626）', () {
    test('_jimakuQuery 的远端分支走 remoteSubtitleSeriesQuery', () {
      final String body = methodBody(code, 'String? _jimakuQuery()');
      expect(
        body,
        contains('remoteSubtitleSeriesQuery('),
        reason: '远端番名必须由该纯函数选词（合集名优先），不要在页面里就地判断——'
            '就地写回去等于把 `Episode 1` 当番名搜。',
      );
      expect(
        body,
        contains('collectionName: _effectiveRemoteInfo?.collection'),
        reason: '番名取**当前**条目的合集名。用 widget.remoteInfo 会在换集后拿到陈旧值。',
      );
      expect(
        body,
        contains(
          'collectionIsWork: _effectiveRemoteClient is RemoteVideoCollectionIsWork',
        ),
        reason: '合集名只在来源声明「合集 = 作品」时参与——互联 host 的合集是用户库里'
            '的任意合集（「待看」），拿它当番名搜必然空手。',
      );
    });

    test('_openSubtitleWorkbench 把集号填进 SubtitleEpisodeSearchSpec', () {
      final String body = methodBody(
        code,
        'Future<void> _openSubtitleWorkbench(',
      );
      expect(
        body,
        contains('episode: _jimakuEpisodeNumber()'),
        reason: '集号必须随请求下发，否则集数框恒空（用户得自己数第几集再手填）。',
      );
    });

    test('集号不许拿播放序兜底', () {
      final String body = methodBody(code, 'int? _jimakuEpisodeNumber()');
      expect(
        body,
        contains('remoteVideoEpisodeNumber('),
        reason: '远端集号只认来源自己报的那个（RemoteVideoEpisodeNumber 能力）。',
      );
      for (final String forbidden in <String>[
        '_currentEpisode',
        'sortIndex',
      ]) {
        expect(
          body.contains(forbidden),
          isFalse,
          reason: '$forbidden 是**播放序**：有特别篇/OVA 或不从第 1 集开始的季度时它与'
              '集号不等。填错的集号比留空更坏——留空只是多几条候选，填错会把用户引到'
              '另一集的字幕上。',
        );
      }
    });
  });
}
