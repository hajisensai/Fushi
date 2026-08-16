import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki.dart' show AnkiMiningSource;

/// 沉浸制卡片段音频的容器扩展名，按平台分（TODO-1217 / BUG-460）：
/// - iOS：`m4a`——AnkiMobile 只自动下载它识别为媒体的 localhost URL，`.aac` 裸流会被当成
///   可见文本不下载（da22cd42a）；iOS 端 ffmpeg-kit 自带 ipod muxer，能产出 `.m4a`。
/// - 桌面 / Android：`aac`（adts）——桌面捆绑的 ffmpeg-min
///   （`tool/ffmpeg-min/build-ffmpeg-min.sh` 的 MUXERS 白名单只有 adts，无 ipod/mp4/m4a）
///   写 `.m4a` 会自动选一个不存在的 ipod muxer → `Unable to choose output format` /
///   exit -22 → `extractAudioSegmentViaFfmpeg` 返 null → 音频丢（桌面网飞/YouTube/应用内
///   视频制卡有图无声，正是 da22cd42a 的桌面回归）；Android AnkiDroid 历来接受 `.aac`（BUG-460）。
///
/// 纯逻辑放在 [immersionMiningAudioExtensionFor]，便于对两分支单测（测试宿主上
/// `Platform.isIOS` 恒为 false，无法直接覆盖 iOS 分支）。
String immersionMiningAudioExtensionFor({required bool isIOS}) =>
    isIOS ? 'm4a' : 'aac';

/// 当前运行平台下沉浸制卡片段音频的容器扩展名（见 [immersionMiningAudioExtensionFor]）。
String immersionMiningAudioExtension() =>
    immersionMiningAudioExtensionFor(isIOS: Platform.isIOS);

/// Immutable locator/title payload for the mined-sentence history row written
/// after a queued video mining request completes.
///
/// The video page can stay mounted while switching episodes, or be disposed
/// while the queue is waiting. Capturing primitive values before enqueue/await
/// prevents the old card from inheriting the new episode's title, locator, or
/// popup fields.
class VideoMiningHistorySnapshot {
  VideoMiningHistorySnapshot.capture({
    required Map<String, String> fields,
    required this.sentence,
    required this.documentTitle,
    required this.bookKey,
    required this.sectionIndex,
    required int? cueStartMs,
    required int? cueEndMs,
    required this.dateKey,
  })  : expression = fields['expression'] ?? '',
        reading = fields['reading'] ?? '',
        glossary = fields['glossary'] ?? '',
        normCharOffset = cueStartMs,
        normCharLength = cueStartMs == null || cueEndMs == null
            ? null
            : (cueEndMs - cueStartMs).clamp(0, 1 << 31).toInt();

  final String expression;
  final String reading;
  final String glossary;
  final String sentence;
  final String documentTitle;
  final String bookKey;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;
  final String dateKey;
}

/// 视频制卡的封面图片模式（用户在 Anki 设置里三选一，默认 [gif]=现状零破坏）：
/// - [gif]：字幕区间动图（现默认，`extractClipGifViaFfmpeg`）。抽取失败按旧阶梯降级为
///   静态帧，并弹「降级为静态帧」OSD。
/// - [currentFrame]：制卡那一刻的当前解码帧（`controller.screenshot`，点词已自动暂停）。
///   用户主动选的静态图，非降级 → 不弹降级 OSD。
/// - [subtitleStart]：当前字幕 cue 起始时间点的帧（`extractVideoFrameViaFfmpeg`，
///   `atSeconds = clipStartMs/1000`）。同为主动选择的静态图。
///
/// 持久化用 [wireName]（存进偏好的字符串），解析用 [fromWireName]（未知值回退 [gif]，
/// 向后兼容）。远端来源（Netflix providedCoverBytes / YouTube）请求不设本字段，保持 [gif]
/// 默认——它们直接给字节或走既有阶梯，不受影响。
enum VideoMiningImageMode {
  gif('gif'),
  currentFrame('current_frame'),
  subtitleStart('subtitle_start');

  const VideoMiningImageMode(this.wireName);

  /// 偏好持久化用的稳定字符串键（勿随枚举名改动）。
  final String wireName;

  /// 从偏好字符串解析；未知/null → [gif]（默认，向后兼容）。
  static VideoMiningImageMode fromWireName(String? name) {
    for (final VideoMiningImageMode mode in VideoMiningImageMode.values) {
      if (mode.wireName == name) return mode;
    }
    return VideoMiningImageMode.gif;
  }

  /// 是否为静态截图模式（用户主动选静态图，非 GIF 降级）。
  bool get isStill => this != VideoMiningImageMode.gif;
}

/// 制卡封面**动图的编码格式**，与 [VideoMiningImageMode] 正交：后者选「用不用动图 +
/// 静态帧取哪一帧」，本枚举选「动图用什么编码」。默认 [avif]。
///
/// 为什么是两个枚举而不是把 avif/webp 并进 [VideoMiningImageMode]：并进去会变成
/// 「格式 × 静态来源」的笛卡尔积（avif/webp/gif × currentFrame/subtitleStart），而格式
/// 只对动图有意义、静态来源只对静态图有意义。两轴独立取值，各自一个设置项。
///
/// 每种格式自己声明**顶格档（最高清晰度档）的参数上限**（[maxTierFps]/[maxTierWidth]）。
/// 这不是装饰性属性——它是顶格档语义的唯一真相源，`MiningMediaCompression.resolve`
/// 直接查它，不做「谁是特例」的分支判断；[capFps]/[capWidth] 再保证任何来路的参数都
/// 越不过本格式的上限。
///
/// 为什么不是一个 `hasInterFrameCompression` 布尔（本改动的初版就是那样，被实测推翻）：
/// 「有没有帧间压缩」是编解码规格问题，而顶格档要回答的是**「这一档跑得动吗」**，
/// 两者并不等价。本机 ffmpeg（libsvtav1 / libwebp_anim / native gif）实测，1080p30
/// 合成源 4 秒窗：
///
/// | 格式 | 标准档 480px·8fps | 源分辨率·源帧率 1080p·30fps |
/// |---|---|---|
/// | gif  | 1973 ms / 471 KB | 11978 ms / 17.8 MB |
/// | webp |  877 ms / 163 KB | **16383 ms** / 5.19 MB |
/// | avif | 2124 ms /  36 KB | **3502 ms** / 3.32 MB |
///
/// WebP 规格上确有帧间差分，实测却是三者里**最慢**的——`libwebp_anim` 本质是逐帧 VP8
/// 帧内编码的静态图编码器，没有真正的运动补偿，也不并行；SVT-AV1 是真视频编码器，
/// 在源分辨率下反而比 GIF 快 3.4 倍。所以 WebP 与 GIF 吃同一组封顶值，AVIF 拿一组
/// **更宽松但同样有限**的封顶值。GIF/WebP 的封顶值仍是 BUG-1039 的实测折中（那次
/// 1080p/4 秒 = 48.9 秒 / 54 MB，10 秒 cue 约 135 MB，撞 120 秒超时且 AnkiConnect 卡死）。
///
/// ⚠️ **没有任何格式的顶格档是「源分辨率 + 源帧率」直通。** AVIF 一度被配成 `0/0`
/// （源直通），按 **10 秒 cue 上限**（`buildFfmpegClipAnimatedArgs` 的 `maxDurationMs`
/// 默认值，而不是上表那个 4 秒窗）重测后撤掉：
///
/// | AVIF 顶格档候选（10 秒窗） | 耗时 | 体积 |
/// |---|---|---|
/// | 4K30 源直通（旧 `0/0`） | 8537 ms | **34.54 MB** |
/// | 1080p30 源直通（旧 `0/0`） | 2485 ms | **8.80 MB** |
/// | **1440px·24fps（现值）** | 2918 ms | **2.91 MB** |
/// | 960px·12fps（= GIF/WebP 封顶值） | 711 ms | 0.41 MB |
/// | 同窗真 GIF @960px·12fps 参照 | 1690 ms | 4.97 MB |
///
/// 换了更好的编码器，该做的是**抬高**上限而不是删掉上限——BUG-1039 的教训是「顶格档
/// 不该是不可用配置」，34 MB 的封面照样把 AnkiConnect 和同步打穿。现值 1440px·24fps
/// 比 GIF/WebP 封顶值宽 1.5 倍、帧率翻倍，产出体积却仍**小于**同窗真 GIF（2.91 MB 对
/// 4.97 MB）。体积预算守卫见 `test/mining/mining_animated_format_test.dart`。
///
/// ⚠️ 默认值是 [avif] 而非 [gif]：这是本改动**唯一一处有意的现状变更**（老用户升级后
/// 新卡默认变 AVIF）。[gif] 保留为可选项，既供用户回退，也供捆绑 ffmpeg 不支持新编码器
/// 时 fail-open 降级（见 `galgame_window_gif.dart` / `desktop_audio_clipper.dart`）。
enum MiningAnimatedFormat {
  avif('avif', 'avif', maxTierFps: 24, maxTierWidth: 1440),
  webp('webp', 'webp', maxTierFps: 12, maxTierWidth: 960),
  gif('gif', 'gif', maxTierFps: 12, maxTierWidth: 960);

  const MiningAnimatedFormat(
    this.wireName,
    this.fileExtension, {
    required this.maxTierFps,
    required this.maxTierWidth,
  });

  /// 偏好持久化用的稳定字符串键（勿随枚举名改动）。
  final String wireName;

  /// 输出文件扩展名（不含点）。ffmpeg 按扩展名选 muxer，故这也是 muxer 选择依据。
  final String fileExtension;

  /// 顶格档帧率上限。恒为正——没有格式开放源帧率直通，理由见枚举文档的两张实测表。
  final int maxTierFps;

  /// 顶格档宽度上限（px）。恒为正——同 [maxTierFps]。
  final int maxTierWidth;

  /// 把 [requested] 帧率夹到本格式的顶格档上限。`<= 0`（历史「源帧率直通」哨兵）同样
  /// 夹成上限。
  ///
  /// 这是 BUG-1039 的收口点：换格式重试时若沿用**上一个格式**的参数，就会把 AVIF 顶格
  /// 档的 24fps/1440px 原样喂给 GIF（GIF 无帧间压缩，体积线性爆炸）。夹取对三种格式、
  /// 四个档位一致，不是「谁是特例」的分支。
  int capFps(int requested) =>
      (requested <= 0 || requested > maxTierFps) ? maxTierFps : requested;

  /// 把 [requested] 宽度夹到本格式的顶格档上限。语义同 [capFps]。
  int capWidth(int requested) =>
      (requested <= 0 || requested > maxTierWidth) ? maxTierWidth : requested;

  /// 编码尝试链：先试本格式，失败降级 [gif] 再试一次；[gif] 自己只有一次尝试（它是链尾
  /// 兜底，没有更低一级可降，也恒可用）。
  ///
  /// 这与 [maxTierFps]/[maxTierWidth] 是同一手法——**降级链是格式自身的属性**，不是各调用
  /// 点各写一遍的三元表达式。改动前视频引擎与 galgame 窗口各持一份拷贝，而 Netflix 录制
  /// 片段那条压根没有链（硬写死 GIF）。三份实现只要漂开一次，就会有一条链路悄悄退回恒 GIF。
  ///
  /// ⚠️ 遍历时每次尝试**必须**用 `attempt` 自己的 [capFps]/[capWidth]/[fileExtension] 重新
  /// 取参：沿用上一个格式的参数（AVIF 顶格档 24fps/1440px）喂给无帧间压缩的 GIF 编码器，
  /// 正是 BUG-1039 那组「48.9 秒 / 54 MB、撞 120 秒超时」的配置。收口点见
  /// `extractAnimatedClipWithFallback`。
  List<MiningAnimatedFormat> get encodeAttempts =>
      this == MiningAnimatedFormat.gif
          ? const <MiningAnimatedFormat>[MiningAnimatedFormat.gif]
          : <MiningAnimatedFormat>[this, MiningAnimatedFormat.gif];

  /// 从偏好字符串解析；未知/null → [avif]（新默认）。
  static MiningAnimatedFormat fromWireName(String? name) {
    for (final MiningAnimatedFormat format in MiningAnimatedFormat.values) {
      if (format.wireName == name) return format;
    }
    return MiningAnimatedFormat.avif;
  }
}

/// 制卡封面**静态截图的编码格式**，与 [VideoMiningImageMode] 正交，也与
/// [MiningAnimatedFormat] 互不相干：模式选「用不用动图 / 静态帧取哪一帧」，本枚举只回答
/// 「静态帧用什么编码」。默认 [jpg] = 现状零破坏。
///
/// 为什么单独一个枚举而不是把 jpg/png 并进 [MiningAnimatedFormat]：那个枚举的每个成员都
/// 带 [MiningAnimatedFormat.maxTierFps]/[MiningAnimatedFormat.maxTierWidth] 这种**只对动图
/// 成立**的属性（帧率对单帧无意义），并进去就得给静图编两个假值，再在取参处分支「这个是
/// 静图别读帧率」。两轴独立取值、各自一个设置项，是同一手法的第三次应用。
///
/// 为什么只有 jpg/png 两档（而不是跟动图一样上 webp/avif）：静图这条链有两个产出点，
/// **一个在 ffmpeg、一个在纯 Dart**（`immersion_mining_engine` 的 `tryCurrentFrame` 拿的是
/// media_kit 的解码帧字节，经 `package:image` 降采样重编码）。`package:image` 能编的只有
/// jpg/png；webp/avif 得把截图字节再喂一次 ffmpeg，多一次进程往返和一层失败降级，而静图
/// 本身体积已经不是瓶颈（4K 帧降到长边 1000px 后 JPEG 约 200KB）。
///
/// [png] 走 [encodeAttempts] 的降级链：捆绑 ffmpeg 缺 png 编码器时退回 [jpg] 再抽一次，
/// 而不是让封面直接丢失（入库的 `ffmpeg-min` 配方 ENCODERS 含 `png`，移动端 ffmpeg-kit
/// 的 min 包同样含 png；链路是给「配方漂了/别的构建」兜底，不是给现状兜底）。
enum MiningStillFormat {
  jpg('jpg', 'jpg'),
  png('png', 'png');

  const MiningStillFormat(this.wireName, this.fileExtension);

  /// 偏好持久化用的稳定字符串键（勿随枚举名改动）。
  final String wireName;

  /// 输出文件扩展名（不含点）。ffmpeg 按扩展名选 muxer，Anki 也按扩展名判 MIME，故这既是
  /// 编码器选择依据，也是媒体库里那张图的真实身份——**扩展名必须跟随实际产出格式**，
  /// 不能跟随用户所选（降级发生时会写出 `.png` 里装 JPEG 的卡，Anki 侧封面不显示）。
  final String fileExtension;

  /// 编码尝试链：先试本格式，失败降级 [jpg] 再试一次；[jpg] 自己只有一次尝试（链尾兜底，
  /// 没有更低一级可降）。与 [MiningAnimatedFormat.encodeAttempts] 同范式。
  List<MiningStillFormat> get encodeAttempts => this == MiningStillFormat.jpg
      ? const <MiningStillFormat>[MiningStillFormat.jpg]
      : <MiningStillFormat>[this, MiningStillFormat.jpg];

  /// 从偏好字符串解析；未知/null → [jpg]（默认，向后兼容）。
  static MiningStillFormat fromWireName(String? name) {
    for (final MiningStillFormat format in MiningStillFormat.values) {
      if (format.wireName == name) return format;
    }
    return MiningStillFormat.jpg;
  }
}

/// 统一沉浸制卡请求。任何来源（本地/YouTube/Netflix）都构造这个喂 [ImmersionMiningEngine]。
///
/// [mediaSource] 是 ffmpeg 的 inputPath——本地绝对路径 或 可 seek 的 http 流 URL。
/// 若 [mediaSource] 为 null（如 Netflix 前台无本地源），引擎只用 [stillFallback] /
/// [providedCoverBytes] / [providedAudioBytes] 组卡。
class ImmersionMiningRequest {
  const ImmersionMiningRequest({
    required this.fields,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.sentence,
    this.mediaSource,
    this.audioSource,
    this.cueSentence,
    this.documentTitle,
    this.audioStreamIndex,
    this.audioStreamCount,
    // BUG-1137：不给默认值。曾默认 video，gal 场景卡忘传 source 就被静默标成
    // 视频；来源必须由每个调用点显式声明，漏传直接编译不过。
    required this.source,
    this.bookTitleTag,
    this.collectionTag,
    this.updateNoteId,
    this.stillFallback,
    this.providedCoverBytes,
    this.providedCoverName,
    this.providedAudioBytes,
    this.providedAudioName,
    this.requireAudio = true,
    this.imageMode = VideoMiningImageMode.gif,
    this.animatedFormat = MiningAnimatedFormat.gif,
    this.stillFormat = MiningStillFormat.jpg,
    this.mediaSourceTlsPinSha256,
    this.remoteAudioClipper,
  });

  final Map<String, String> fields;
  final int clipStartMs;
  final int clipEndMs;
  final String sentence;
  final String? mediaSource;

  /// 音频段抽取源（ffmpeg inputPath）。null = 用 [mediaSource]（本地文件/muxed）。
  /// YouTube 分离流时 = audio-only 流 URL（视频流无音轨，音频得从这里裁）。
  final String? audioSource;
  final String? cueSentence;
  final String? documentTitle;
  final int? audioStreamIndex;
  final int? audioStreamCount;
  final AnkiMiningSource source;
  final String? bookTitleTag;

  /// 合集/系列名标签（视频=播放列表系列名）：与 [bookTitleTag] 同「自动添加书名到标签」
  /// 开关，非 null 时经 [BaseAnkiRepository.buildNoteTags] 追加为独立 tag。不属合集/单视频
  /// 无系列名时为 null。透传进 [AnkiMiningContext.collectionTag]。
  final String? collectionTag;

  /// 非 null = 覆盖现有卡（走 updateMinedNote，不计统计）。
  final int? updateNoteId;

  /// 当前解码帧兜底（本地路径链全失败时）。本地传 `controller.screenshot`。
  final Future<Uint8List?> Function()? stillFallback;

  /// 外部已抓好的封面/音频字节（Netflix 后台实例直接给字节，无本地文件）。
  final Uint8List? providedCoverBytes;
  final String? providedCoverName;
  final Uint8List? providedAudioBytes;
  final String? providedAudioName;

  /// true = 无音频则中止制卡（本地/YouTube 默认）；false = 允许无音频卡（Netflix 2A 截图卡）。
  final bool requireAudio;

  /// 视频制卡封面图片模式（见 [VideoMiningImageMode]）。默认 [VideoMiningImageMode.gif]
  /// = 现状。仅本地/有 range 的封面解析路径读取；providedCoverBytes 路径不受影响。
  final VideoMiningImageMode imageMode;

  /// 动图编码格式（见 [MiningAnimatedFormat]）。仅 [imageMode] 为
  /// [VideoMiningImageMode.gif]（= 用动图）时生效。
  ///
  /// 这里默认 [MiningAnimatedFormat.gif] 而**用户偏好默认 avif**，两者不矛盾：值对象的
  /// 默认只服务「没显式指定的调用点/测试」，保证它们逐字节等价于改动前；用户可见的默认
  /// 由 `MiningAnimatedFormat.fromWireName(null)` 给出（= avif），真实调用点一律显式透传
  /// 偏好。与 [imageMode] 的默认取法一致。
  final MiningAnimatedFormat animatedFormat;

  /// 静态截图编码格式（见 [MiningStillFormat]）。仅 [imageMode] 为静态档
  /// （[VideoMiningImageMode.isStill]），或动图抽取失败降级成静态帧时生效。
  ///
  /// 默认取法与 [animatedFormat] 一致：值对象默认 [MiningStillFormat.jpg]（= 改动前的
  /// 硬编码 `.jpg`，没显式指定的调用点/测试逐字节等价），用户可见的默认由
  /// `MiningStillFormat.fromWireName(null)` 给出（同为 jpg），真实调用点显式透传偏好。
  final MiningStillFormat stillFormat;

  /// BUG-891：[mediaSource]/[audioSource] 若是远端自签 Hibiki 主机的 https 流，这里带上
  /// 该 host 经 TOFU 钉扎的证书 SHA-256 指纹（`aa:bb:..`）。引擎把它透传给 ffmpeg 抽取器的
  /// `-tls_pin_sha256`，使自编 ffmpeg-kit（`--enable-gnutls` + pin 补丁）按指纹接受自签，
  /// 而非无条件放行。null = 本地源 / 公网有效证书源（YouTube 等），不钉扎、走 ffmpeg 默认。
  final String? mediaSourceTlsPinSha256;

  /// BUG-1004：互联 host（LAN Hibiki 库）远端流的句子音频改由 **host 端**裁好再下载——host
  /// 用本地文件裁、不经网络/TLS，从根上绕开「client ffmpeg 抓 host 自签 https / token 流」的
  /// 整类失败（移动端自编 ffmpeg-kit 的 TLS pin 仍有残余缺口、URL 编码/网络脆弱等，见
  /// BUG-891）。非空且 [audioSource]/[mediaSource] 命中远端 http(s) 时优先调用：返回裁好的
  /// 本地音频文件路径即成功，返回 null 则回退现有 ffmpeg-over-URL 抽取（老 host 无 `clipaudio`
  /// 端点时的兼容路径，Never break userspace）。本地/YouTube/直链源不注入（为 null）。
  final Future<String?> Function({
    required int startMs,
    required int endMs,
    required String outputPath,
  })? remoteAudioClipper;

  bool get hasRange => clipEndMs > clipStartMs;

  /// 入队前冻结所有可变输入。视频页可能在任务真正执行前已经换集或关闭弹窗；队列里的
  /// 卡必须继续使用点击制卡那一刻的字段和外部媒体字节，不能读到调用方后续修改。
  ImmersionMiningRequest frozen() => ImmersionMiningRequest(
        fields: Map<String, String>.unmodifiable(
          Map<String, String>.from(fields),
        ),
        clipStartMs: clipStartMs,
        clipEndMs: clipEndMs,
        sentence: sentence,
        mediaSource: mediaSource,
        audioSource: audioSource,
        cueSentence: cueSentence,
        documentTitle: documentTitle,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
        source: source,
        bookTitleTag: bookTitleTag,
        collectionTag: collectionTag,
        updateNoteId: updateNoteId,
        stillFallback: stillFallback,
        providedCoverBytes: providedCoverBytes == null
            ? null
            : Uint8List.fromList(providedCoverBytes!),
        providedCoverName: providedCoverName,
        providedAudioBytes: providedAudioBytes == null
            ? null
            : Uint8List.fromList(providedAudioBytes!),
        providedAudioName: providedAudioName,
        requireAudio: requireAudio,
        imageMode: imageMode,
        animatedFormat: animatedFormat,
        stillFormat: stillFormat,
        mediaSourceTlsPinSha256: mediaSourceTlsPinSha256,
        remoteAudioClipper: remoteAudioClipper,
      );
}

/// 引擎产出。[outcome] 用 Object? 承 MineOutcome，避免此值对象文件依赖 anki_models 全量。
class ImmersionMiningResult {
  const ImmersionMiningResult({
    required this.aborted,
    this.outcome,
    this.degradedToStill = false,
    this.abortReason,
  });

  /// true = 因缺音频等前置条件中止，未调后端。
  final bool aborted;

  /// MineOutcome（成功路径）。
  final Object? outcome;
  final bool degradedToStill;

  /// TODO-1303：仅在 [aborted] 时非空——中止的人类可读原因（缺音频 / 空壳卡）。远端
  /// 制卡（浏览器扩展）据此把失败原因写进错误日志并随响应体回传，终结「制卡失败报成功
  /// + 诊断黑洞」。null（成功路径）时无诊断。
  final String? abortReason;
}
