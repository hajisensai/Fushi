import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/range_playback.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

/// 「高级制卡」对话框（查词弹窗里「+」旁边的按钮）的**能力契约**。
///
/// 对话框本身是纯 UI：它只认这里定义的分区。每个分区为 null = 这个页面没有这项能力，
/// 对话框整块不渲染（纯查词页只有卡组；漫画没有句子音频；视频没有裁切……）。
///
/// 职责切分：
/// * 打开对话框、把查词弹窗停到屏外、确认后回点弹窗的「+」（`mineEntryByIndex`，带上
///   [MiningRequestOverrides]）——`BaseSourcePage` / `DictionaryPageMixin` 的开窗函数。
/// * 卡组分区 [AdvancedMiningDeckSection]——开窗函数按 Anki 设置统一组装，页面不管。
/// * 句子 / 音频 / 图片分区 [AdvancedMiningSections]——各页面覆写
///   `buildAdvancedMiningSections` 提供。
/// * 用户的选择编码成 [MiningRequestOverrides] 并进本次制卡的 fields map，由各页面的
///   制卡路径在**同步前缀**里读出来（不挂页面状态，见该类注释）。

/// 对话框确认：把本次覆盖项交给开窗函数去回点弹窗「+」。返回是否真的点到了
/// 那颗按钮（BUG-2627：没点到要如实提示，不静默关窗）。
///
/// [wordAudioUrl]：本次单词音频的选择（[AdvancedMiningWordAudioSection]）。null = 没改，
/// 按一键「+」现解析默认源；空串 = 不要单词音频；否则是弹窗可播 URL（远端 `http(s)`、
/// 本地 `data:`），由查词弹窗层在交宿主前改写进制卡 fields 的 `audio`。它不进
/// [MiningRequestOverrides]：那是要上互联 / 扩展 wire 的契约，而单词音频本来就随
/// fields 的 `audio` 走，没有第二条通道。
typedef AdvancedMiningConfirm =
    Future<bool> Function(
      MiningRequestOverrides overrides, {
      String? wordAudioUrl,
    });

/// 卡组分区。
class AdvancedMiningDeckSection {
  const AdvancedMiningDeckSection({
    required this.decks,
    required this.defaultDeckName,
    this.setDefaultDeck,
  });

  /// 可选卡组名（Anki 设置里已拉取的 `availableDecks`，按名字排序）。空列表 = 还没连过
  /// Anki，对话框只显示默认卡组名、不给下拉。
  final List<String> decks;

  /// 设置里当前的卡组（一键「+」会写进的那个）；null = 尚未选择。
  final String? defaultDeckName;

  /// 「同时设为默认卡组」：持久化到 Anki 设置（走 `AnkiViewModel.selectDeck`）。null =
  /// 该表面不允许改默认（不渲染复选框）。
  final Future<void> Function(String deckName)? setDefaultDeck;
}

/// 单词音频的一个候选：某个启用音频源解析出的一条（远端列表型源会展开成多个变体）。
/// 与查词弹窗 ♪「选择音频源」菜单同一份数据（`listWordAudioSources` 桥）。
class AdvancedMiningWordAudioChoice {
  const AdvancedMiningWordAudioChoice({
    required this.name,
    required this.variant,
    required this.url,
  });

  /// 源的显示名（用户起的名字 / host / 「TTS 兜底」）；别的设备给的结果可能为空。
  final String name;

  /// 同一源下的变体（说话人等）；没有时为空。
  final String variant;

  /// 弹窗可直接播放的 URL（远端 `http(s)`、本地文件转成的 `data:`）。
  final String url;

  /// 同一个候选的身份：确认时重新解析后按它找回（远端互联源的 URL 带短时令牌，
  /// 不能拿打开对话框时的旧 URL 去制卡，见 popup.js 的 TODO-766）。
  bool sameSourceAs(AdvancedMiningWordAudioChoice other) =>
      other.name == name && other.variant == variant;
}

/// 单词音频分区：所有制卡表面都有（与卡组分区一样由开窗函数统一组装）。
///
/// 第一项就是一键「+」会用的那条（[listChoices] 与弹窗默认解析共用同一个解析器），
/// 所以「选第一项」等价于不改。
class AdvancedMiningWordAudioSection {
  const AdvancedMiningWordAudioSection({
    required this.listChoices,
    required this.preview,
    required this.stopPreview,
  });

  /// 当前词每个启用音频源各自解析出的候选（按音频源配置顺序）。空 = 这个词没有发音。
  final Future<List<AdvancedMiningWordAudioChoice>> Function() listChoices;

  /// 试听一条候选；返回是否真的开始播放。
  final Future<bool> Function(String url) preview;

  final Future<void> Function() stopPreview;
}

/// 句子分区：沿用原「调整上下文」对话框的宿主回调（语义不变，见 [MiningSentenceDraft]）。
class AdvancedMiningSentenceSection {
  const AdvancedMiningSentenceSection({
    required this.fetchPreview,
    required this.setContext,
    this.editSentence,
    this.removeSentence,
  });

  /// `{prev:[str], current:str, currentOffset:int?, next:[str], prevRemoved:[bool],
  /// nextRemoved:[bool], total:int}`（[buildSentenceContextPreview]）。
  final Future<Map<String, Object?>> Function() fetchPreview;

  /// 整体设置「上 prev 句 / 下 next 句」，返回上下文句总数。
  final Future<int> Function(int prev, int next) setContext;

  final Future<void> Function(SentenceContextSlot slot, int index, String text)?
  editSentence;

  final Future<void> Function(
    SentenceContextSlot slot,
    int index,
    bool removed,
  )?
  removeSentence;
}

/// 写进卡片的句子音频区间（宿主时间轴毫秒，已含首尾留白、A/V 偏移与本次起止偏移）。
class AdvancedMiningAudioWindow {
  const AdvancedMiningAudioWindow({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;
}

/// 句子音频分区。所有回调都收**本次的起止偏移**（对话框持有，确认时并进覆盖项），
/// 宿主据此算出与写卡完全一致的区间——试听与写卡同源（BUG-2196 ②）。
class AdvancedMiningAudioSection {
  const AdvancedMiningAudioSection({
    required this.describe,
    required this.preview,
    required this.stopPreview,
    this.nudgeStepMs = 250,
  });

  /// 当前会写进卡片的区间；null = 这句没有可用音频（对话框显示「无音频」，不给微调）。
  /// 每次加减句子、改偏移后对话框都会重新调用。
  final Future<AdvancedMiningAudioWindow?> Function(
    int startDeltaMs,
    int endDeltaMs,
  )
  describe;

  /// 试听那段区间。返回 null = 没有可试听的音频；否则返回这次区间播放的句柄，它在
  /// 这段**播完或被打断**时完成——对话框的「正在试听」只跟它走（FDN66-xurt：曾只在
  /// 起播失败 / 显式停止时复位，播完后按钮停在「停止」，下一次点击只是去停）。
  ///
  /// 宿主可以起播后立即返回，也可以等播完才返回（有声书片段播放器即如此）；两种对话框
  /// 都按句柄收尾。
  final Future<RangePlayback?> Function(int startDeltaMs, int endDeltaMs)
  preview;

  final Future<void> Function() stopPreview;

  /// 起止微调的步长。
  final int nudgeStepMs;
}

/// 视频图片分区。
class AdvancedMiningVideoImageSection {
  const AdvancedMiningVideoImageSection({
    required this.modes,
    required this.defaultMode,
    this.frameAt,
    this.frameStepMs = 42,
    this.lookupFrameMs,
    this.subtitleStartMs,
  });

  /// 这个来源可选的图片方式（模板不支持视频片段时不含 [VideoMiningImageMode.videoClip]）。
  /// 对话框另外总会给一个「不要」。
  final List<VideoMiningImageMode> modes;

  /// 设置里的图片方式（一键「+」的行为）。
  final VideoMiningImageMode defaultMode;

  /// 取某个时刻（播放器轴毫秒）的缩略图字节（JPEG/PNG）；null 回调 = 这个来源取不到
  /// 帧（远端流且缓存不可用），对话框只显示时间戳，偏移照样能调；回调返回 null =
  /// 这一帧没取到。
  final Future<Uint8List?> Function(int atMs)? frameAt;

  /// 逐帧挪动的步长（毫秒，来自 mpv `container-fps`，取不到按 24fps）。
  final int frameStepMs;

  /// 「查词时画面」那一帧的时刻（播放器轴毫秒，查词瞬间记下）；null = 不可用。
  /// 宿主在对话框打开时就已经把这一帧截下锁住，试听挪动播放头不影响它。
  final int? lookupFrameMs;

  /// 「字幕开头」那一帧的时刻（播放器轴毫秒，未留白的句首）；null = 不可用。
  final int? subtitleStartMs;
}

/// 漫画裁切的预选建议（相对原页图的 0..1 归一化坐标）。
class MangaCropSuggestions {
  const MangaCropSuggestions({
    required this.pageIndex,
    required this.pageSize,
    this.panels = const <Rect>[],
    this.containingPanel,
    this.textRect,
    this.textAreaRect,
  });

  /// 被裁的那一页（查词命中的那一页）。
  final int pageIndex;

  /// 原页图像素尺寸（`bakeOrientation` 之后）。
  final Size pageSize;

  /// 检测到的全部分镜（阅读顺序）；分镜模型不可用 / 条漫时为空。
  final List<Rect> panels;

  /// 这句话所在的分镜；没有分镜时 null。
  final Rect? containingPanel;

  /// 这句话的 OCR 文本块并集；拿不到 OCR 位置时 null。
  final Rect? textRect;

  /// 文本块外扩后的建议框（模型不可用时的预选）；null = 退回整页。
  final Rect? textAreaRect;
}

/// 漫画图片分区。
class AdvancedMiningMangaImageSection {
  const AdvancedMiningMangaImageSection({
    required this.loadPage,
    required this.loadSuggestions,
    required this.panelModelAvailable,
    this.downloadPanelModel,
    this.panelModelSizeBytes,
  });

  /// 原页图字节（不是屏幕渲染）。
  final Future<Uint8List?> Function() loadPage;

  /// 预选建议（分镜检测可能要几百毫秒，所以是异步的）。
  final Future<MangaCropSuggestions?> Function() loadSuggestions;

  /// 分镜模型是否已下载可用（与「分镜导航」开关无关）。
  final bool panelModelAvailable;

  /// 下载分镜模型；返回已收字节流，结束 = 下载完成。null = 不提供下载入口。
  final Stream<int> Function()? downloadPanelModel;

  /// 模型大小（给「下载（9.8 MB）」文案用）。
  final int? panelModelSizeBytes;
}

/// 静态截图分区（galgame texthooker：这句台词对应的窗口截图）。
///
/// 只给预览与「打码」：宿主在对话框打开时冻结一帧，[loadImage] 交出的就是确认后进卡
/// 的那一张（预览与出卡同源）。
class AdvancedMiningStillImageSection {
  const AdvancedMiningStillImageSection({
    required this.loadImage,
    this.mosaicForcesStill = false,
    this.historicalLine = false,
  });

  /// 冻结的那一帧截图（PNG / JPEG 字节）；null = 抓不到（对话框如实显示「截图不可用」，
  /// 不给打码）。
  final Future<Uint8List?> Function() loadImage;

  /// 一键「+」出的是动图 / 视频片段：打了码就改出静图，对话框据此提示用户。
  final bool mosaicForcesStill;

  /// 制卡的是历史台词（不是最新一行）：截图只能是打开对话框那一刻的窗口画面，不是
  /// 那句台词当时的画面——对话框如实提示（与协调器的 staleScene 同一判据）。
  final bool historicalLine;
}

/// 页面提供的句子 / 音频 / 图片分区（卡组由开窗函数统一组装）。
class AdvancedMiningSections {
  const AdvancedMiningSections({
    this.sentence,
    this.audio,
    this.videoImage,
    this.mangaImage,
    this.stillImage,
    this.onClosed,
  });

  static const AdvancedMiningSections none = AdvancedMiningSections();

  final AdvancedMiningSentenceSection? sentence;
  final AdvancedMiningAudioSection? audio;
  final AdvancedMiningVideoImageSection? videoImage;
  final AdvancedMiningMangaImageSection? mangaImage;
  final AdvancedMiningStillImageSection? stillImage;

  /// 对话框关闭（确认或取消）后调用：停试听、把视频播放头放回查词位置、释放缓存副本等。
  final Future<void> Function()? onClosed;
}

/// 对话框收到的全部输入。
class AdvancedMiningCapabilities {
  const AdvancedMiningCapabilities({
    required this.matched,
    this.deck,
    this.wordAudio,
    required this.sections,
    required this.onConfirm,
    this.expression,
  });

  /// 查到的词在句中的表现形（当前句高亮用）。
  final String matched;

  /// 词条原形（标题行用）；null 时用 [matched]。
  final String? expression;

  /// null = 这个表面不能选卡组（例如手机遥控电脑制卡：卡组由电脑决定）。
  final AdvancedMiningDeckSection? deck;

  /// null = 这个表面选不了单词音频（拿不到候选列表）。
  final AdvancedMiningWordAudioSection? wordAudio;
  final AdvancedMiningSections sections;
  final AdvancedMiningConfirm onConfirm;
}
