// 反馈日志里的「视频性能诊断」一节（反馈 MReV894ote，BUG 见 docs/bugs）。
//
// 视频卡顿 / 掉帧的判据（每秒一行的 `[mpv/stats]` 迟帧 / 丢帧 / 上屏
// `present window=… lost=…`、`[frame] video-page` 的 build / raster 耗时）只写进
// `video_diag_log.txt`（[VideoDiagLog]），从不进错误日志或调试日志，所以用户开着
// 视频诊断、复现完卡顿再提交反馈，附上来的日志里一行性能数据都没有。
//
// 这里只摘**白名单类别**的行：会话 / 视频页生命周期 / 帧耗时 / mpv 属性采样 / 内存
// 策略 / 热槽，以及 libmpv 转写行里 warn 及以上的。这些行只含毫秒数、计数、平台
// 与解码参数，不含片名与路径；查词（`lookup`）与弹窗（`popup`）两类带查询词，
// libmpv 的 verbose 转写行带文件路径 / 流 URL，一律不收（需要时让用户走
// 「设置 › 诊断 › 导出视频诊断日志」整份导出）。整份文件上限 4 MB，只读末尾一段。

import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/diagnostics/video_diag_log.dart';

/// 读文件末尾的字节上限（时间轴单文件上限 4 MB，只要最近的一段）。
const int kFeedbackVideoDiagTailBytes = 2 * 1024 * 1024;

/// 最多带这么多行（取最近的）。播放中每秒约 3 行（属性采样 + 上屏统计 + 帧汇总），
/// 3600 行约合 20 分钟连续播放，文本约 700 KB，gzip 后远低于反馈日志上限。
const int kFeedbackVideoDiagMaxLines = 3600;

/// 原样收录的类别（精确匹配）。
const Set<String> kFeedbackVideoDiagCategories = <String>{
  VideoDiagCategory.session,
  VideoDiagCategory.video,
  VideoDiagCategory.frame,
  VideoDiagCategory.mpvStats,
  VideoDiagCategory.memory,
  VideoDiagCategory.warmSlot,
};

/// libmpv 转写行（`mpv/<模块>`）只收这几级：报错与告警值得和其它域对时刻，verbose
/// 行已在 `video_mpv_log.txt` 里且带路径 / URL。
const Set<String> kFeedbackVideoDiagMpvLevels = <String>{
  'fatal',
  'error',
  'warn',
};

/// 行格式见 [VideoDiagLog.formatLine]：`<日期> <时间> [  秒.毫秒][级别][类别] 消息`。
final RegExp _kLineHead = RegExp(
  r'^\S+ \S+ \[\s*\d+\.\d+\]\[([a-z]+)\]\[([^\]]+)\] ',
);

/// 从 [raw]（video_diag_log.txt 的一段文本）里摘白名单行，保留最近 [maxLines] 行，
/// 并按 [redactVideoDiagSecrets] 抹掉令牌。
List<String> videoDiagFeedbackLines(
  String raw, {
  int maxLines = kFeedbackVideoDiagMaxLines,
}) {
  final List<String> kept = <String>[];
  for (final String line in const LineSplitter().convert(raw)) {
    final RegExpMatch? m = _kLineHead.firstMatch(line);
    if (m == null) continue;
    final String level = m.group(1)!;
    final String category = m.group(2)!;
    final bool keep =
        kFeedbackVideoDiagCategories.contains(category) ||
        (category.startsWith('${VideoDiagCategory.mpv}/') &&
            kFeedbackVideoDiagMpvLevels.contains(level));
    if (keep) kept.add(redactVideoDiagSecrets(line));
  }
  return kept.length <= maxLines ? kept : kept.sublist(kept.length - maxLines);
}

/// 读 [file]（默认 [VideoDiagLog.timelineFile]）末尾 [tailBytes] 字节并摘白名单行。
/// 文件不存在 / 诊断从没开过 / 读失败都返回空列表——这一节只是锦上添花，不能让反馈
/// 提交失败。同步读：与 [readGalLookupDiagnosticLines] 一样只读末尾 2 MB，在
/// `collectFeedbackLogText` 这个同步汇总点里调用。
List<String> readVideoDiagFeedbackLines({
  File? file,
  int tailBytes = kFeedbackVideoDiagTailBytes,
}) {
  final File? source = file ?? VideoDiagLog.instance.timelineFile;
  if (source == null) return const <String>[];
  RandomAccessFile? handle;
  try {
    if (!source.existsSync()) return const <String>[];
    handle = source.openSync();
    final int length = handle.lengthSync();
    final int start = length > tailBytes ? length - tailBytes : 0;
    handle.setPositionSync(start);
    final List<int> bytes = handle.readSync(length - start);
    String text = utf8.decode(bytes, allowMalformed: true);
    if (start > 0) {
      // 从中间截开的首行不完整，丢掉。
      final int firstBreak = text.indexOf('\n');
      text = firstBreak < 0 ? '' : text.substring(firstBreak + 1);
    }
    return videoDiagFeedbackLines(text);
  } on FileSystemException {
    return const <String>[];
  } finally {
    handle?.closeSync();
  }
}
