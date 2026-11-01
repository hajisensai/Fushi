/// 视频制卡「句子音频」从哪里采（反馈 pNF2ZL7Kfc）。
///
/// 三种来源：
/// - [SentenceAudioSourceKind.currentTrack]（默认 = 改动前的行为）：正在播放的那条音轨，
///   ffmpeg 参数与改动前逐字节相同。
/// - [SentenceAudioSourceKind.selectedTrack]：用户指定的第 N 条音轨（可与正在播放的
///   不同——典型用法是用户自己把人声分离出来封成 mkv 的一条音轨）。
/// - [SentenceAudioSourceKind.frontCenter]：多声道（5.1 / 5.1(side) / 7.1…）资源的中置
///   声道 FC。电影 / 动画的多声道混音里对白基本只在 FC，取它就去掉了大部分背景音乐与
///   音效（ffmpeg `pan=mono|c0=FC`）。
///
/// 取不到所选来源（指定的音轨不存在、源不是多声道 / 声道布局里没有 FC）时**回退到当前
/// 播放音轨并提示用户**，绝不静默——这是 [planSentenceAudioSource] 的契约。
library;

/// 来源种类。持久化用 [wireName]（勿随枚举名改动）。
enum SentenceAudioSourceKind {
  currentTrack('current'),
  selectedTrack('track'),
  frontCenter('front_center');

  const SentenceAudioSourceKind(this.wireName);

  final String wireName;
}

/// 一次选择：种类 + 指定音轨的序号（0-based，在「真实音轨」里的位置，即 ffmpeg
/// `0:a:N` 的 N；UI 显示 1-based）。只有 [SentenceAudioSourceKind.selectedTrack] 读
/// [trackOrdinal]。
///
/// wire 形态（偏好与高级制卡覆盖项共用）：`current` / `front_center` / `track:<N>`。
class SentenceAudioSourcePick {
  const SentenceAudioSourcePick._(this.kind, this.trackOrdinal);

  static const SentenceAudioSourcePick currentTrack = SentenceAudioSourcePick._(
    SentenceAudioSourceKind.currentTrack,
    0,
  );

  static const SentenceAudioSourcePick frontCenter = SentenceAudioSourcePick._(
    SentenceAudioSourceKind.frontCenter,
    0,
  );

  /// 第 [ordinal] 条音轨（0-based；负数夹成 0）。
  factory SentenceAudioSourcePick.track(int ordinal) =>
      SentenceAudioSourcePick._(
        SentenceAudioSourceKind.selectedTrack,
        ordinal < 0 ? 0 : ordinal,
      );

  final SentenceAudioSourceKind kind;
  final int trackOrdinal;

  bool get isDefault => kind == SentenceAudioSourceKind.currentTrack;

  String get wireName => switch (kind) {
    SentenceAudioSourceKind.selectedTrack => 'track:$trackOrdinal',
    _ => kind.wireName,
  };

  /// 解析 [wireName]；null / 空 / 未知 / 坏序号一律回退 [currentTrack]（= 改动前行为）。
  static SentenceAudioSourcePick fromWireName(String? raw) {
    final String value = raw?.trim() ?? '';
    if (value == SentenceAudioSourceKind.frontCenter.wireName) {
      return frontCenter;
    }
    const String trackPrefix = 'track:';
    if (value.startsWith(trackPrefix)) {
      final int? ordinal = int.tryParse(value.substring(trackPrefix.length));
      if (ordinal != null && ordinal >= 0) {
        return SentenceAudioSourcePick.track(ordinal);
      }
    }
    return currentTrack;
  }

  /// [fromWireName] 的可空版：null / 空 → null（高级制卡「没改来源」）。
  static SentenceAudioSourcePick? tryFromWireName(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return fromWireName(raw);
  }

  @override
  bool operator ==(Object other) =>
      other is SentenceAudioSourcePick &&
      other.kind == kind &&
      other.trackOrdinal == trackOrdinal;

  @override
  int get hashCode => Object.hash(kind, trackOrdinal);

  @override
  String toString() => 'SentenceAudioSourcePick($wireName)';
}

/// 一条音轨制卡时用得到的事实（来自播放器的轨道元数据）。
class SentenceAudioTrackInfo {
  const SentenceAudioTrackInfo({this.channelLayout, this.channelCount});

  /// 声道布局名：mpv `demux-channels`（`5.1(side)` / `stereo` / `fl-fr-fc-lfe-…`）或
  /// ffprobe `channel_layout`（`5.1(side)` / `FL+FR+FC+LFE+SL+SR`）。null = 未知。
  final String? channelLayout;

  /// 声道数；null = 未知。
  final int? channelCount;
}

/// 取不到所选来源的原因（每个都要提示用户）。
enum SentenceAudioFallbackReason {
  /// 指定的第 N 条音轨在这个视频里不存在。
  trackMissing,

  /// 声道布局确定没有 FC（立体声 / 单声道 / quad 等）。
  noFrontCenter,

  /// 声道布局未知，抽取前探测（ffprobe）也没能确认有 FC。
  frontCenterUnknown,

  /// 中置声道抽取本身失败（已改用当前播放音轨重抽）。
  frontCenterFailed,
}

/// 这一次句子音频怎么抽。
class SentenceAudioSourcePlan {
  const SentenceAudioSourcePlan({
    required this.audioStreamIndex,
    this.frontCenter = false,
    this.frontCenterNeedsProbe = false,
    this.fallback,
  });

  /// ffmpeg `-map 0:a:N` 的 N；null = 不加 `-map`（跟随默认，= 改动前）。
  final int? audioStreamIndex;

  /// 取中置声道（`-af pan=mono|c0=FC`）。
  final bool frontCenter;

  /// [frontCenter] 为真但播放器没报声道布局：引擎抽取前先用 ffprobe 确认有 FC，
  /// 确认不了就回退并提示（[SentenceAudioFallbackReason.frontCenterUnknown]）。
  final bool frontCenterNeedsProbe;

  /// 非 null = 没取到所选来源、已回退到当前播放音轨，必须提示用户。
  final SentenceAudioFallbackReason? fallback;

  /// 与当前播放音轨不同（指定了另一条轨）：播放器缓冲副本里只有当前播放的那条，
  /// 这种请求不能用副本抽。
  bool differsFromPlaying(int? playingIndex) =>
      audioStreamIndex != null && audioStreamIndex != playingIndex;
}

/// 定下这一次句子音频怎么抽。纯函数。
///
/// - [pick]：设置里的来源，或高级制卡本次的临时覆盖（调用方先 `override ?? setting`）。
/// - [playingIndex]：当前播放音轨的序号（`currentAudioStreamIndex`，null = 跟随默认）。
/// - [tracks]：真实音轨（去掉 auto/no），按 ffmpeg `0:a:N` 顺序。
///
/// 回退一律回到「当前播放音轨」（= [playingIndex]，与默认来源完全同一组参数）。
SentenceAudioSourcePlan planSentenceAudioSource({
  required SentenceAudioSourcePick pick,
  required int? playingIndex,
  required List<SentenceAudioTrackInfo> tracks,
}) {
  switch (pick.kind) {
    case SentenceAudioSourceKind.currentTrack:
      return SentenceAudioSourcePlan(audioStreamIndex: playingIndex);
    case SentenceAudioSourceKind.selectedTrack:
      if (pick.trackOrdinal >= tracks.length) {
        return SentenceAudioSourcePlan(
          audioStreamIndex: playingIndex,
          fallback: SentenceAudioFallbackReason.trackMissing,
        );
      }
      // 只有一条轨时选它就是选默认：不加 -map，参数与默认来源逐字节相同。
      if (tracks.length == 1) {
        return SentenceAudioSourcePlan(audioStreamIndex: playingIndex);
      }
      return SentenceAudioSourcePlan(audioStreamIndex: pick.trackOrdinal);
    case SentenceAudioSourceKind.frontCenter:
      final int ordinal = playingIndex ?? 0;
      final SentenceAudioTrackInfo? track = ordinal < tracks.length
          ? tracks[ordinal]
          : null;
      final bool? hasCenter = channelLayoutHasFrontCenter(
        track?.channelLayout,
        channelCount: track?.channelCount,
      );
      if (hasCenter == false) {
        return SentenceAudioSourcePlan(
          audioStreamIndex: playingIndex,
          fallback: SentenceAudioFallbackReason.noFrontCenter,
        );
      }
      // 中置模式一律显式 map：抽取前的布局探测与真正裁的必须是同一条轨（ffmpeg 不加
      // -map 时默认挑声道最多的那条，未必是正在播的）。
      return SentenceAudioSourcePlan(
        audioStreamIndex: ordinal,
        frontCenter: true,
        frontCenterNeedsProbe: hasCenter == null,
      );
  }
}

/// ffmpeg / mpv 的具名布局里**含 FC** 的那些（小写）。
const Set<String> _kNamedLayoutsWithFrontCenter = <String>{
  '3.0',
  '4.0',
  '3.1',
  '4.1',
  '5.0',
  '5.0(side)',
  '5.1',
  '5.1(side)',
  '6.0',
  '6.1',
  '6.1(back)',
  '6.1(top)',
  '7.0',
  '7.0(front)',
  '7.0(rear)',
  '7.1',
  '7.1(wide)',
  '7.1(wide-side)',
  '7.1(top)',
  '7.1(rear)',
  '3.1.2',
  '5.1.2',
  '5.1.2(back)',
  '5.1.4',
  '7.1.2',
  '7.1.4',
  '7.2.3',
  '9.1.4',
  'hexagonal',
  'octagonal',
  'hexadecagonal',
  '22.2',
};

/// 具名布局里**确定没有 FC** 的（小写）。`mono` 在 ffmpeg 里就是 FC 一路，但单声道
/// 本身就没有「背景音乐在别的声道」可去，按「不是多声道」回退。
const Set<String> _kNamedLayoutsWithoutFrontCenter = <String>{
  'mono',
  'stereo',
  'downmix',
  '2.1',
  '3.0(back)',
  'quad',
  'quad(side)',
  '6.0(front)',
  '6.1(front)',
  'cube',
};

/// 声道布局里有没有中置声道 FC：true / false / null（判断不了）。纯函数。
///
/// 认三种写法：具名布局（`5.1(side)`）、ffprobe 的 `+` 连接（`FL+FR+FC+LFE`，也包括
/// `6 channels (FL+FR+FC+LFE+BL+BR)`）、mpv 的 `-` 连接（`fl-fr-fc-lfe-sl-sr`）。
/// 布局未知（null / 空 / `unknown6` 之类）时返回 null——**不按声道数猜**：6 声道不一定
/// 是 5.1，猜错了 `pan` 会静默输出无声的片段。[channelCount] 只用来判定单声道 /
/// 立体声这种不可能有独立 FC 的情况。
bool? channelLayoutHasFrontCenter(String? layout, {int? channelCount}) {
  if (channelCount != null && channelCount > 0 && channelCount < 3) {
    return false;
  }
  final String value = layout?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return null;
  if (_kNamedLayoutsWithFrontCenter.contains(value)) return true;
  if (_kNamedLayoutsWithoutFrontCenter.contains(value)) return false;
  // 显式声道表：`fl+fr+fc+…`、`6 channels (fl+fr+fc…)`、`fl-fr-fc-…`。
  final String inner = value.contains('(') && value.endsWith(')')
      ? value.substring(value.indexOf('(') + 1, value.length - 1)
      : value;
  final List<String> tokens = inner
      .split(RegExp(r'[+\-|\s]+'))
      .where((String t) => t.isNotEmpty)
      .toList(growable: false);
  if (tokens.length < 2) return null;
  const Set<String> speakerNames = <String>{
    'fl', 'fr', 'fc', 'lfe', 'bl', 'br', 'flc', 'frc', 'bc', 'sl', 'sr', //
    'tc', 'tfl', 'tfc', 'tfr', 'tbl', 'tbc', 'tbr', 'dl', 'dr', 'wl', 'wr',
    'sdl', 'sdr', 'lfe2', 'tsl', 'tsr', 'bfc', 'bfl', 'bfr', 'na',
  };
  // 每个记号都得是声道名才算「显式声道表」；混进别的东西（如 `unknown6`）按未知。
  if (!tokens.every(speakerNames.contains)) return null;
  return tokens.contains('fc');
}
