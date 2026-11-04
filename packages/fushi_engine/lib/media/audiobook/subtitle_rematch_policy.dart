/// Sasayaki 重匹配的格式策略（纯数据，无 UI）。
///
/// 原来和「弹 searchWindow slider 再跑 matcher」的 UI 流程同住 app 的
/// `subtitle_rematch.dart`；对齐执行器（引擎）只需要格式判定，所以拆出来。
/// app 侧 `SubtitleRematch` 的同名静态成员全部委派到这里，行为不变。
library;

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';

class SubtitleRematchPolicy {
  const SubtitleRematchPolicy._();

  /// 有声书字幕格式（[kAudiobookSubtitleExtensions]）全部走 matcher；SMIL/JSON 有硬
  /// 时间码锚点，与 window 无关。此前这里手抄成 srt/lrc/vtt/ass，漏了 ssa——ssa 与
  /// ass 同一个解析器，却因此既不跑 matcher、导入前的探测也返回空。
  static const Set<String> supportedFormats = kAudiobookSubtitleExtensions;

  /// 硬时间码格式，matcher 无能为力，直接排除。
  static const Set<String> nonMatcherFormats = <String>{'smil', 'json'};

  static bool isEligible(Audiobook ab) {
    final String fmt = ab.alignmentFormat.toLowerCase();
    final String ext = extFromPath(ab.alignmentPath);
    if (nonMatcherFormats.contains(fmt) || nonMatcherFormats.contains(ext)) {
      return false;
    }
    return true;
  }

  /// 小写扩展名；无扩展名返回空串。
  static String extFromPath(String path) {
    if (path.isEmpty) {
      return '';
    }
    final String last = path.split('.').last.toLowerCase();
    if (last == path.toLowerCase()) {
      return '';
    }
    return last;
  }
}
