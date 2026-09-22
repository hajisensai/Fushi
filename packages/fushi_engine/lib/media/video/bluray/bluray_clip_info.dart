// 蓝光盘片段信息（`BDMV/CLIPINF/*.clpi`）里我们唯一需要的东西：这段 m2ts 的**呈现
// 区间**，也就是它自己的首帧与末帧时间戳。
//
// 它只回答一个判据，但这个判据决定播放形态：这条 PlayItem 是不是把整段从头用到尾。
// 若是，就能把这段直接当成普通视频文件交给播放器，省掉一层 EDL 包装，让下游所有吃
// 「真实文件路径」的链路（ffmpeg 抽封面、内嵌字幕探测、制卡裁剪）原样继续工作；否则
// 才需要按 IN/OUT 截取。光看 MPLS 判不出来——IN/OUT 是绝对 PTS，m2ts 的首个 PTS 几乎
// 从不为 0（常见在 0x0BB8 附近起跳，也有从几百秒起跳的盘），拿 IN 和 0 比毫无意义。
//
// 注意**不要**拿这里的零点去减 EDL 的起点：EDL 的 `start` 与源包的原始 PTS 同域，减
// 了会让那一段播不出来（详见 `bluray_source.dart` 文件头）。
//
// 只解 SequenceInfo，其余段（ProgramInfo / CPI / ClipMark）一概不碰：那些信息 MPLS
// 的 STN table 已经给过，重复解析只会多一份出错面。
//
// 解析失败返回 null，由调用方退化成「零点未知」。

import 'dart:typed_data';

import 'bluray_playlist.dart' show kBlurayTimeScale;

/// 一段 m2ts 在自身时间轴上的呈现区间（45kHz ticks）。
class BlurayClipTimebase {
  const BlurayClipTimebase({
    required this.presentationStartTicks,
    required this.presentationEndTicks,
  });

  final int presentationStartTicks;
  final int presentationEndTicks;

  int get durationTicks => presentationEndTicks - presentationStartTicks;

  Duration get duration =>
      Duration(microseconds: durationTicks * 1000000 ~/ kBlurayTimeScale);
}

/// 解析一份 CLPI，取第一个 ATC 序列的第一个 STC 序列的呈现起止时间。
///
/// 多 ATC/STC 的盘（无缝分支）里后面的序列描述的是同一段的不同接续点，时间零点仍由
/// 第一个决定，所以只读第一个就够。
BlurayClipTimebase? parseBlurayClipTimebase(Uint8List bytes) {
  if (bytes.length < 0x28) return null;
  if (String.fromCharCodes(bytes, 0, 4) != 'HDMV') return null;

  final ByteData view = ByteData.sublistView(bytes);
  // 头部：4B 类型 | 4B 版本 | 4B SequenceInfo 起址 | 4B ProgramInfo 起址 | ...
  final int sequenceInfoStart = view.getUint32(8);
  if (sequenceInfoStart <= 0 || sequenceInfoStart + 6 > bytes.length) {
    return null;
  }

  final int length = view.getUint32(sequenceInfoStart);
  final int end = sequenceInfoStart + 4 + length;
  if (length < 2 || end > bytes.length) return null;

  // uint32 length | 1B 保留 | 1B ATC 序列数
  final int atcCount = bytes[sequenceInfoStart + 5];
  if (atcCount == 0) return null;

  // 第一个 ATC：4B SPN_ATC_start | 1B STC 序列数 | 1B offset_STC_id
  int p = sequenceInfoStart + 6;
  if (p + 6 > end) return null;
  final int stcCount = bytes[p + 4];
  if (stcCount == 0) return null;
  p += 6;

  // 第一个 STC：2B PCR_PID | 4B SPN_STC_start | 4B 呈现起 | 4B 呈现止
  if (p + 14 > end) return null;
  final int startTicks = view.getUint32(p + 6);
  final int endTicks = view.getUint32(p + 10);
  if (endTicks <= startTicks) return null;

  return BlurayClipTimebase(
    presentationStartTicks: startTicks,
    presentationEndTicks: endTicks,
  );
}
