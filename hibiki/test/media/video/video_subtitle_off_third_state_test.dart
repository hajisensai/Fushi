import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:path/path.dart' as p;

import '../../pages/video_hibiki_page_source_corpus.dart';

/// TODO-818：视频字幕「关闭」第三态。
///
/// 根因：`VideoBooks.subtitleSource`（TEXT nullable）原本只有「非空=选了具体源」与
/// `null` 两态，把「用户显式关闭」和「从未选过/无偏好」压成同一 `null`。恢复路径见
/// `null` 就退「自动选默认」，导致用户明明关了字幕、重启又被自动选上。选某条具体轨
/// 持久化为非空值（绝对路径 / `embedded:<n>`）故能记住，唯独「关闭」记不住。
///
/// 修法：补全数据结构第三态——新增 [SubtitleSource.offSentinel]（`'off:'`）哨兵，复用
/// 同一 TEXT 列、零 schema 改动。写入端存哨兵；两个自动重选向量（sidecar 探测 + 内嵌轨
/// 自动抽取）见哨兵都短路；恢复/菜单端识别哨兵=「关闭」。旧 `null` 仍按「无偏好→自动
/// 选默认」处理（向后兼容铁律）。
///
/// media_kit 无法 headless 跑（`_loadSingle`/`_loadEpisode`/`controller.load` 都驱动真
/// Player），故这里用纯函数断言哨兵语义 + 源码守卫钉两个自动向量的短路调用点。
void main() {
  group('SubtitleSource.offSentinel 第三态语义（纯函数）', () {
    test('哨兵是固定的 "off:" 字符串，与内嵌/外挂命名空间不撞', () {
      expect(SubtitleSource.offSentinel, 'off:');
      // 与内嵌前缀不同命名空间：embedded:<n> 永不等于裸 off:。
      expect(
          SubtitleSource.offSentinel.startsWith(SubtitleSource.embeddedPrefix),
          isFalse);
      // 没有任何真实外挂路径会恰好是裸 "off:"（无扩展名、无目录分隔）。
      expect(SubtitleSource.offSentinel.contains('/'), isFalse);
      expect(SubtitleSource.offSentinel.contains(r'\'), isFalse);
    });

    test('isOff(哨兵)=true：用户显式关闭', () {
      expect(SubtitleSource.isOff(SubtitleSource.offSentinel), isTrue);
      expect(SubtitleSource.isOff('off:'), isTrue);
    });

    test('向后兼容：isOff(null)=false，旧 null 仍当「无偏好→自动选默认」', () {
      expect(SubtitleSource.isOff(null), isFalse);
    });

    test('isOff 不误伤具体源：外挂路径 / embedded:<n> / 空串都不是关闭', () {
      expect(SubtitleSource.isOff(r'D:\v\a.ja.srt'), isFalse);
      expect(SubtitleSource.isOff('/data/video_subtitles/x.srt'), isFalse);
      expect(SubtitleSource.isOff('embedded:0'), isFalse);
      expect(SubtitleSource.isOff('embedded:3'), isFalse);
      expect(SubtitleSource.isOff(''), isFalse);
    });

    test('具体源的 toPersistedValue 永远不会撞上关闭哨兵', () {
      const SubtitleSource embedded = SubtitleSource.embedded(
        streamIndex: 0,
        label: 'x',
      );
      const SubtitleSource external = SubtitleSource.external(
        externalPath: r'D:\v\a.srt',
        label: 'a.srt',
      );
      expect(embedded.toPersistedValue(), isNot(SubtitleSource.offSentinel));
      expect(external.toPersistedValue(), isNot(SubtitleSource.offSentinel));
      expect(SubtitleSource.isOff(embedded.toPersistedValue()), isFalse);
      expect(SubtitleSource.isOff(external.toPersistedValue()), isFalse);
    });
  });

  group('TODO-818 源码守卫：关闭哨兵堵住两个自动重选向量', () {
    final String src = readVideoHibikiSource();

    String region(String startSig, String endSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
      final int end = src.indexOf(endSig, start + startSig.length);
      expect(end, greaterThan(start),
          reason: 'missing $endSig after $startSig');
      return src.substring(start, end);
    }

    test('_selectSubtitleOff 持久化 offSentinel 而非 null', () {
      final String body = region(
        'Future<void> _selectSubtitleOff(',
        'Widget _subtitleJumpSidePanel(',
      );
      expect(body.contains('SubtitleSource.offSentinel'), isTrue,
          reason: '关字幕必须存哨兵，否则与「无偏好」null 撞、重启又自动选上');
      // 不再把 null 当关闭写入：本方法体内的 saveSubtitleSelection / updateSubtitleSource
      // 不应再传 `subtitleSource: null`。
      expect(body.contains('subtitleSource: null'), isFalse,
          reason: '关闭不能再写 null（会被恢复路径当无偏好自动选默认）');
    });

    test('_loadSingle 见哨兵短路：不退 sidecar 探测', () {
      final String body = region(
        'Future<void> _loadSingle(',
        'Future<({String persisted, List<AudioCue> cues, int? graphicStreamIndex})?>',
      );
      expect(body.contains('SubtitleSource.isOff(row.subtitleSource)'), isTrue,
          reason: '单视频恢复必须先识别显式关闭哨兵');
      // 哨兵分支必须先于 sidecar 探测，且 isOff 判据在 _detectSidecar 之前出现。
      final int offIdx = body.indexOf('SubtitleSource.isOff');
      final int sidecarIdx = body.indexOf('_detectSidecar');
      expect(offIdx, greaterThanOrEqualTo(0));
      expect(sidecarIdx, greaterThan(offIdx), reason: '关闭判据必须在 sidecar 探测之前短路');
    });

    test('_loadEpisode 见哨兵短路：不退 sidecar 探测', () {
      final String body = region(
        'Future<void> _loadEpisode(',
        'Future<({String path, List<AudioCue> cues})?> _detectSidecar(',
      );
      expect(body.contains('SubtitleSource.isOff(subtitleSource)'), isTrue,
          reason: '换集恢复也要识别显式关闭哨兵（作用域=整张 video book）');
      final int offIdx = body.indexOf('SubtitleSource.isOff');
      final int sidecarIdx = body.indexOf('_detectSidecar');
      expect(offIdx, greaterThanOrEqualTo(0));
      expect(sidecarIdx, greaterThan(offIdx));
    });

    test('_applyLoad 把关闭哨兵透传成 subtitleExplicitlyOff，堵内嵌轨自动抽取', () {
      final String body = region(
        'Future<void> _applyLoad(',
        'void _handleEmbeddedSubtitleAutoLoad(',
      );
      expect(
        body.contains(
            'subtitleExplicitlyOff: SubtitleSource.isOff(externalSubtitlePath)'),
        isTrue,
        reason: '显式关闭时必须告诉 controller 别后台抽内嵌文本轨成 cue',
      );
    });

    test('controller.load 的内嵌轨自动抽取被 subtitleExplicitlyOff 门控', () {
      final String controllerSrc = File(
        p.join(
          Directory.current.path,
          'lib',
          'src',
          'media',
          'video',
          'video_player_controller.dart',
        ),
      ).readAsStringSync().replaceAll('\r\n', '\n');

      // load() 必须接受显式关闭入参。
      expect(
          controllerSrc.contains('bool subtitleExplicitlyOff = false'), isTrue,
          reason: 'load 需要明确的「显式关闭」入参');
      // 内嵌文本轨自动抽取分支必须先判 !subtitleExplicitlyOff 才进。
      final int branchIdx =
          controllerSrc.indexOf('_loadEmbeddedSubtitleIfNeeded(');
      expect(branchIdx, greaterThanOrEqualTo(0));
      final int gateIdx = controllerSrc.indexOf('!subtitleExplicitlyOff');
      expect(gateIdx, greaterThanOrEqualTo(0),
          reason: '内嵌轨自动抽取必须被 !subtitleExplicitlyOff 门控');
      expect(gateIdx, lessThan(branchIdx), reason: '门控判据必须在自动抽取调用之前');
    });
  });
}
