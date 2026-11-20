/// HDR 片源制卡的色调映射（拍板台 design-nmv-hdr-mining-tonemap）。
///
/// 播放侧由 libmpv / libplacebo 把 HDR10（PQ）与 HLG 映射到 SDR，但制卡走 ffmpeg 抽帧 /
/// 动图 / 片段，原先没有映射：10-bit BT.2020 PQ 码值被直接编进 8-bit BT.709 产物，
/// 卡图发灰、饱和度只剩原片三分之一（PR #3828 测量组 m4 实测）。
///
/// 修法不用 zscale + tonemap：zscale 依赖 libzimg，统一 FFmpeg 只有 Windows 构建带它。
/// 统一 FFmpeg（`tool/ffmpeg-unified/recipe.env`，n9.0.1）的 swscale 自带色彩管理
/// （`libswscale/cms.c`、`format.c`，无条件编译、不依赖外部库）：`scale` 滤镜的
/// `out_transfer` / `out_primaries` 触发 PQ / HLG → BT.709 的转换，`intent=perceptual`
/// 选 ST 2094 拐点的样条色调映射（与播放侧 libplacebo 默认的 spline 同一套算法），
/// 源峰值取 mastering display 元数据。五个平台随包的是同一版 FFmpeg，行为一致，
/// 不需要给任何平台重编 FFmpeg。
///
/// 只对 HDR 源加这一段：它对 SDR 源**不是**无操作——实测矩阵标 bt709、primaries /
/// transfer 未标的 SDR 片源经它后亮度逐位相同，色度 PSNR 只有 21 dB。所以先按源的
/// `color_transfer` 判定，只有 PQ / HLG 才映射，SDR 片源的命令逐字不变。
///
/// Linux 用系统 FFmpeg、`FUSHI_FFMPEG` 可指到任意版本：老版本的 `scale` 不认这些选项，
/// 喂进去整条命令会失败。按实际后端问一次 `-h filter=scale`，不认就不加（产物同改前，
/// 不会失败），并记一条诊断。
library;

import 'dart:async';
import 'dart:collection';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:meta/meta.dart';

/// HDR → SDR 映射的 `scale` 滤镜段。矩阵一并改成 BT.709：输出已是 BT.709 色域与
/// 传递函数，留着 BT.2020 矩阵会让只认 601 / 709 的下游（JPEG 解码器等）解错色相。
const String kFfmpegHdrToSdrScaleFilter =
    'scale=out_transfer=bt709:out_primaries=bt709:out_color_matrix=bt709:'
    'intent=perceptual';

/// `color_transfer` 里需要映射的 HDR 传递函数（ffprobe 打印的名字）。
const Set<String> kFfmpegHdrTransfers = <String>{'smpte2084', 'arib-std-b67'};

/// 纯函数：ffprobe `stream=color_transfer`（`default=nw=1:nk=1`）的输出是否是 HDR 传递函数。
bool ffprobeTransferIsHdr(String stdout) {
  for (final String line in stdout.split(RegExp(r'\r?\n'))) {
    if (kFfmpegHdrTransfers.contains(line.trim())) return true;
  }
  return false;
}

/// 纯函数：`ffmpeg -h filter=scale` 的帮助文本是否带 swscale 色彩管理所需的选项。
bool ffmpegScaleHelpSupportsToneMap(String help) =>
    help.contains('out_transfer') &&
    help.contains('out_primaries') &&
    help.contains('intent') &&
    help.contains('perceptual');

/// 纯函数：探首条视频流传递函数的 ffprobe 参数。[inputArgs] 是远端输入的协议选项
/// （`buildFfmpegRemoteInputArgs` 的结果，本地文件为空），放在输入前。
List<String> buildFfprobeVideoTransferArgs({
  required String inputPath,
  List<String> inputArgs = const <String>[],
}) => <String>[
  ...inputArgs,
  '-v',
  'error',
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=color_transfer',
  '-of',
  'default=nw=1:nk=1',
  inputPath,
];

Future<bool>? _scaleToneMapSupport;
bool _loggedMissingSupport = false;

/// 同一片源只探一次：进度条缩略图、制卡的帧 / 动图 / 片段对同一路径会连发多次。
const int _kSourceCacheCapacity = 64;
final LinkedHashMap<String, Future<bool>> _sourceIsHdr =
    LinkedHashMap<String, Future<bool>>();

/// 当前 ffmpeg 后端的 `scale` 是否支持 swscale 色彩管理（进程内只问一次，失败按不支持）。
Future<bool> ffmpegSupportsHdrToneMap() => _scaleToneMapSupport ??= () async {
  try {
    final FfmpegRunResult result = await resolveFfmpegBackend().runQuery(
      const <String>['-hide_banner', '-h', 'filter=scale'],
      const Duration(seconds: 15),
    );
    return ffmpegScaleHelpSupportsToneMap(result.output);
  } on Object {
    return false;
  }
}();

Future<bool> _probeSourceIsHdr(String inputPath, List<String> inputArgs) async {
  try {
    final FfmpegRunResult result = await resolveFfmpegBackend().runProbe(
      buildFfprobeVideoTransferArgs(inputPath: inputPath, inputArgs: inputArgs),
      const Duration(seconds: 20),
    );
    if (result.returnCode != 0) return false;
    return ffprobeTransferIsHdr(result.output);
  } on Object {
    // 缺 ffprobe / 打不开：按 SDR 处理，命令保持改前的形状。
    return false;
  }
}

/// [inputPath] 的首条视频流是不是 HDR10 / HLG（按路径缓存，最近使用的留下）。
Future<bool> ffmpegSourceIsHdr(
  String inputPath, {
  List<String> inputArgs = const <String>[],
}) {
  final Future<bool> result =
      _sourceIsHdr.remove(inputPath) ?? _probeSourceIsHdr(inputPath, inputArgs);
  _sourceIsHdr[inputPath] = result;
  while (_sourceIsHdr.length > _kSourceCacheCapacity) {
    _sourceIsHdr.remove(_sourceIsHdr.keys.first);
  }
  return result;
}

/// 这次对 [inputPath] 的抽帧 / 动图 / 片段要不要加 [kFfmpegHdrToSdrScaleFilter]：
/// 源是 HDR **且**后端支持。
Future<bool> ffmpegShouldToneMapToSdr(
  String inputPath, {
  List<String> inputArgs = const <String>[],
}) async {
  final Future<bool> supported = ffmpegSupportsHdrToneMap();
  final bool hdr = await ffmpegSourceIsHdr(inputPath, inputArgs: inputArgs);
  if (!hdr) return false;
  if (await supported) return true;
  if (!_loggedMissingSupport) {
    _loggedMissingSupport = true;
    engineLog.logDiagnostic(
      'ffmpeg-hdr-tonemap',
      'HDR source but this ffmpeg build has no swscale colour management '
          '(scale out_transfer / intent); card media is not tone-mapped',
    );
  }
  return false;
}

@visibleForTesting
void debugResetFfmpegHdrToneMapState() {
  _scaleToneMapSupport = null;
  _loggedMissingSupport = false;
  _sourceIsHdr.clear();
}
