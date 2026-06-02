import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// 生效探针级别（精确度递减；详见设计 §5）。
enum EffectTier { t1RenderInput, t2WidgetTree, t3WebViewDom, t4Behavior }

/// 一次渲染输入的快照（生成函数的输出串）。
class EffectSnapshot {
  const EffectSnapshot(this.output);
  final String output;
}

/// 探针比对结论：是否生效 + 证据。
class EffectVerdict {
  const EffectVerdict({required this.changed, required this.evidence});
  final bool changed;

  /// 变化后的输出片段（含新值），写进报告供核查。
  final String evidence;
}

/// T1：阅读器 CSS 渲染输入探针。比对 `ReaderContentStyles.css` 的输出串，
/// 证明设置真的流进了渲染管线输入（跨平台、不依赖 WebView）。
class ReaderCssEffectProbe {
  ReaderCssEffectProbe(this._settings);

  final ReaderSettings Function() _settings;

  EffectTier get kind => EffectTier.t1RenderInput;

  EffectSnapshot capture() =>
      EffectSnapshot(ReaderContentStyles.css(settings: _settings()));

  EffectVerdict compare(EffectSnapshot before, EffectSnapshot after) {
    if (before.output == after.output) {
      return const EffectVerdict(changed: false, evidence: '');
    }
    return EffectVerdict(
        changed: true, evidence: _firstDiffLine(before, after));
  }

  /// 取 after 里第一行与 before 不同的内容当证据。
  String _firstDiffLine(EffectSnapshot before, EffectSnapshot after) {
    final Set<String> beforeLines = before.output.split('\n').toSet();
    for (final String line in after.output.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty) continue;
      if (!beforeLines.contains(line)) return t;
    }
    return after.output.split('\n').firstWhere(
          (String l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
  }
}
