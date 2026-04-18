import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';

/// Sasayaki 匹配信息在 `AudioCue.textFragmentId` 上的编码方案。
///
/// 约定：
/// - 命中的 cue：`sasayaki://s=<sectionIndex>&ns=<normStart>&ne=<normEnd>`
/// - 未命中的 cue：保留原来的 `srt://<n>` / DOM id 等原值，不被改写
///
/// 这样做的好处：不用改 Isar schema / .g.dart，同一份 `AudioCue` 既可服务
/// cues→epub 合成书（用现有 `[data-cue-id]` 高亮），也可服务 Sasayaki
/// 风格的原生 EPUB 匹配（用 normChar 偏移定位）。
class SasayakiMatchCodec {
  static const String _scheme = 'sasayaki://';

  /// 编码命中结果为 textFragmentId。
  static String encodeHit({
    required int sectionIndex,
    required int normCharStart,
    required int normCharEnd,
  }) {
    return '${_scheme}s=$sectionIndex&ns=$normCharStart&ne=$normCharEnd';
  }

  /// 若 [raw] 不是 sasayaki:// 形式则返回 null。
  static SasayakiFragment? tryDecode(String raw) {
    if (!raw.startsWith(_scheme)) {
      return null;
    }
    final String body = raw.substring(_scheme.length);
    int? s;
    int? ns;
    int? ne;
    for (final String pair in body.split('&')) {
      final int eq = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final String k = pair.substring(0, eq);
      final String v = pair.substring(eq + 1);
      final int? iv = int.tryParse(v);
      if (iv == null) {
        continue;
      }
      switch (k) {
        case 's':
          s = iv;
        case 'ns':
          ns = iv;
        case 'ne':
          ne = iv;
      }
    }
    if (s == null || ns == null || ne == null) {
      return null;
    }
    return SasayakiFragment(
      sectionIndex: s,
      normCharStart: ns,
      normCharEnd: ne,
    );
  }

  /// 把匹配结果写回 cues 的 `textFragmentId`。
  ///
  /// [cues] 与 `result.matches` 必须一一对应（相同顺序 / 相同 sentenceIndex）。
  ///
  /// 未命中的 cue：[clearUnmatched] 为 true（默认）时将 `textFragmentId` 置空，
  /// 供 bridge 跳过无效的 `[data-cue-id="N"]` 回落选择器（普通 EPUB 里根本没
  /// 这种 span，每次 tick 都 diagTickMiss 刷屏）。set 为 false 则保留原值，
  /// 适合字幕合成书路径（`CuesToEpub` 生成的 EPUB 里确实存在 data-cue-id span）。
  ///
  /// 返回新增命中的数量。
  static int applyToCues({
    required List<AudioCue> cues,
    required MatchResult result,
    bool clearUnmatched = true,
  }) {
    if (cues.length != result.matches.length) {
      throw ArgumentError(
        'cues.length (${cues.length}) != matches.length '
        '(${result.matches.length})',
      );
    }
    int applied = 0;
    for (int i = 0; i < cues.length; i++) {
      final CueMatch m = result.matches[i];
      if (m.matched) {
        cues[i].textFragmentId = encodeHit(
          sectionIndex: m.sectionIndex,
          normCharStart: m.normCharStart,
          normCharEnd: m.normCharEnd,
        );
        applied++;
      } else if (clearUnmatched) {
        cues[i].textFragmentId = '';
      }
    }
    return applied;
  }

  /// 从已保存的 cues 反向统计匹配率。
  ///
  /// 适合进入书架/阅读器时做一次轻量计算，避免在 schema 上新增字段。
  static double computeMatchRate(List<AudioCue> cues) {
    if (cues.isEmpty) {
      return 0;
    }
    int hit = 0;
    for (final AudioCue c in cues) {
      if (c.textFragmentId.startsWith(_scheme)) {
        hit++;
      }
    }
    return hit / cues.length;
  }
}

/// 解码后的 Sasayaki fragment。
class SasayakiFragment {
  const SasayakiFragment({
    required this.sectionIndex,
    required this.normCharStart,
    required this.normCharEnd,
  });

  final int sectionIndex;
  final int normCharStart;
  final int normCharEnd;
}
