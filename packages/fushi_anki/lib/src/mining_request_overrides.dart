import 'dart:convert';

import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;

/// 漫画卡图的裁切矩形：**相对原页图**（`bakeOrientation` 之后）的 0..1 归一化坐标。
///
/// 与分镜检测 `PanelRect` 同一坐标系，所以「所在分镜」可以不经换算直接落进来。
/// [pageIndex] 是被裁的那一页（双页模式下 = 查词命中的那一页），与宿主的
/// `_miningPageIndex` 对账：两者不一致时宿主应放弃裁切、退回整页，绝不裁错页。
class MiningImageCrop {
  const MiningImageCrop({
    required this.pageIndex,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// 解析 [toJson] 的产物；字段缺失 / 非数字 / 退化矩形一律返回 null（宁可整页也不裁出
  /// 一张空图）。
  static MiningImageCrop? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? page = raw['page'];
    final double? l = _num(raw['l']);
    final double? t = _num(raw['t']);
    final double? r = _num(raw['r']);
    final double? b = _num(raw['b']);
    if (page is! num || l == null || t == null || r == null || b == null) {
      return null;
    }
    final MiningImageCrop crop = MiningImageCrop(
      pageIndex: page.toInt(),
      left: l,
      top: t,
      right: r,
      bottom: b,
    ).clamped();
    return crop.isDegenerate ? null : crop;
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  final int pageIndex;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// 整页（不需要裁）：四边都贴着页面边缘。
  bool get isWholePage => left <= 0 && top <= 0 && right >= 1 && bottom >= 1;

  /// 宽或高不足页面的 1%：当成无效输入，不裁。
  bool get isDegenerate => width < 0.01 || height < 0.01;

  /// 夹进 0..1，并保证 left<=right、top<=bottom。
  MiningImageCrop clamped() {
    double c(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
    final double l = c(left), r = c(right), t = c(top), b = c(bottom);
    return MiningImageCrop(
      pageIndex: pageIndex,
      left: l < r ? l : r,
      top: t < b ? t : b,
      right: l < r ? r : l,
      bottom: t < b ? b : t,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'page': pageIndex,
    'l': left,
    't': top,
    'r': right,
    'b': bottom,
  };

  @override
  bool operator ==(Object other) =>
      other is MiningImageCrop &&
      other.pageIndex == pageIndex &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(pageIndex, left, top, right, bottom);
}

/// 卡图上的一块打码区域：**相对未裁切原图**的 0..1 归一化矩形。
///
/// 坐标系与 [MiningImageCrop] 相同（漫画 = `bakeOrientation` 之后的原页图；视频 /
/// galgame = 那一帧截图本身）。打码先于裁切落到原图上，所以用户改了取景框也不必换算
/// 打码位置，预览与出卡共用同一套坐标。
class MiningMosaicRegion {
  const MiningMosaicRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// 解析 [toJson] 的产物；字段缺失 / 非数字 / 退化矩形返回 null。
  static MiningMosaicRegion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final double? l = _num(raw['l']);
    final double? t = _num(raw['t']);
    final double? r = _num(raw['r']);
    final double? b = _num(raw['b']);
    if (l == null || t == null || r == null || b == null) return null;
    final MiningMosaicRegion region = MiningMosaicRegion(
      left: l,
      top: t,
      right: r,
      bottom: b,
    ).clamped();
    return region.isDegenerate ? null : region;
  }

  /// 解析一组区域，坏项逐个丢弃（不因一项坏掉而丢掉整组打码）。
  static List<MiningMosaicRegion> listFromJson(Object? raw) {
    if (raw is! List) return const <MiningMosaicRegion>[];
    return List<MiningMosaicRegion>.unmodifiable(<MiningMosaicRegion>[
      for (final Object? item in raw)
        if (fromJson(item) case final MiningMosaicRegion region) region,
    ]);
  }

  static double? _num(Object? v) =>
      v is num && v.isFinite ? v.toDouble() : null;

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// 宽或高不足图像的 0.5%：当成误触，不打码。
  bool get isDegenerate => width < 0.005 || height < 0.005;

  /// 夹进 0..1，并保证 left<=right、top<=bottom。
  MiningMosaicRegion clamped() {
    double c(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
    final double l = c(left), r = c(right), t = c(top), b = c(bottom);
    return MiningMosaicRegion(
      left: l < r ? l : r,
      top: t < b ? t : b,
      right: l < r ? r : l,
      bottom: t < b ? b : t,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'l': left,
    't': top,
    'r': right,
    'b': bottom,
  };

  @override
  bool operator ==(Object other) =>
      other is MiningMosaicRegion &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'MiningMosaicRegion($left, $top, $right, $bottom)';
}

/// 「高级制卡」对话框里用户为**这一张卡**做的调整（只对本次请求生效，不改任何设置）。
///
/// 为什么走制卡请求的 fields map 而不是挂在页面 / AppModel 上：阅读器制卡串行队列
/// 是异步启动的（`serial_task_queue.dart` 的 `_tail.then`），挂在页面上的覆盖项会被
/// 前面已排队的普通「+」读走；fields map 是制卡请求的唯一载体，待发队列、互联转发、
/// 「看完再制卡」暂存都原样保留它（与 `AnkiMiningPayload.withAllowDuplicate` 同一先例）。
///
/// wire 形态：[wireKey] → JSON 字符串（应用内桥是全字符串 `Map<String, String>`）；
/// 保类型线（扩展 / 远端 API）上也接受直接是 Map。旧主机不认识这个键 → 忽略 →
/// 卡照常按主机自己的默认设置制作。
class MiningRequestOverrides {
  const MiningRequestOverrides({
    this.deckName,
    this.omitAudio = false,
    this.audioStartDeltaMs = 0,
    this.audioEndDeltaMs = 0,
    this.audioSource,
    this.omitImage = false,
    this.videoImageMode,
    this.coverFrameAtMs,
    this.crop,
    this.mosaic = const <MiningMosaicRegion>[],
    this.fieldValues = const <String, String>{},
  });

  /// fields map 里的键名。
  static const String wireKey = 'miningOverrides';

  /// 本次写进哪个卡组（按名字，Anki 的卡组名全库唯一）；null = 用设置里的卡组。
  /// 后端在 `availableDecks` 里找不到这个名字时退回设置里的卡组并留诊断，不新建卡组。
  final String? deckName;

  /// 不要句子音频。
  final bool omitAudio;

  /// 句子音频起点偏移（毫秒，负数 = 提前）。加在宿主算好（含首尾留白与 A/V 偏移）的
  /// **最终区间**上，不夹相邻句——用户就是要越过边界。
  final int audioStartDeltaMs;

  /// 句子音频终点偏移（毫秒，正数 = 推后）。同 [audioStartDeltaMs]。
  final int audioEndDeltaMs;

  /// 视频句子音频来源：`SentenceAudioSourcePick.wireName`（current / front_center /
  /// `track:<N>`）；null = 用设置。本包不依赖引擎，所以存 wire 字符串。
  final String? audioSource;

  /// 不要卡图（封面 / 截图 / 动图 / 视频片段都不要）。
  final bool omitImage;

  /// 视频图片方式：`VideoMiningImageMode.wireName`（gif / current_frame /
  /// subtitle_start / video_clip）；null = 用设置。本包不依赖引擎，所以存 wire 字符串。
  final String? videoImageMode;

  /// 静态封面取哪一帧（视频时间轴毫秒，播放器轴）；null = 按图片方式的默认帧。
  /// 用户在对话框里逐帧挪过首帧时由宿主填入。
  final int? coverFrameAtMs;

  /// 漫画卡图裁切；null = 不裁（整页，或按「一键制卡默认裁到分镜」设置）。
  final MiningImageCrop? crop;

  /// 卡图打码区域（相对未裁切原图，见 [MiningMosaicRegion]）；空 = 不打码。
  ///
  /// 非空时宿主**只能**出静态图（动图 / 视频片段逐帧打码做不到所见即所得），且打码
  /// 失败时宁可不要卡图也不能退回原图——用户打码就是不想让那块进卡。
  final List<MiningMosaicRegion> mosaic;

  /// 用户在对话框里手改的卡片字段（Anki 字段名 → 写进卡片的值，反馈 -K86qlwBg6）。
  ///
  /// 只含**真的改过**的字段：值非空才算改，空串 / 纯空白在编解码时一律丢弃（对话框里
  /// 留空 = 照常按字段映射自动生成）。宿主渲染完映射后用它整段替换同名字段
  /// （`AnkiNoteComposer.buildMinedFields`），不在映射里的字段名不会凭空多写一个字段。
  final Map<String, String> fieldValues;

  bool get hasMosaic => mosaic.isNotEmpty;

  bool get hasAudioDelta => audioStartDeltaMs != 0 || audioEndDeltaMs != 0;

  /// 什么都没改：等价于普通一键制卡，调用方不必往 fields 里写任何东西。
  bool get isEmpty =>
      deckName == null &&
      !omitAudio &&
      !hasAudioDelta &&
      audioSource == null &&
      !omitImage &&
      videoImageMode == null &&
      coverFrameAtMs == null &&
      crop == null &&
      mosaic.isEmpty &&
      fieldValues.isEmpty;

  MiningRequestOverrides copyWith({
    String? deckName,
    bool clearDeckName = false,
    bool? omitAudio,
    int? audioStartDeltaMs,
    int? audioEndDeltaMs,
    String? audioSource,
    bool clearAudioSource = false,
    bool? omitImage,
    String? videoImageMode,
    bool clearVideoImageMode = false,
    int? coverFrameAtMs,
    bool clearCoverFrameAtMs = false,
    MiningImageCrop? crop,
    bool clearCrop = false,
    List<MiningMosaicRegion>? mosaic,
    Map<String, String>? fieldValues,
  }) => MiningRequestOverrides(
    deckName: clearDeckName ? null : (deckName ?? this.deckName),
    omitAudio: omitAudio ?? this.omitAudio,
    audioStartDeltaMs: audioStartDeltaMs ?? this.audioStartDeltaMs,
    audioEndDeltaMs: audioEndDeltaMs ?? this.audioEndDeltaMs,
    audioSource: clearAudioSource ? null : (audioSource ?? this.audioSource),
    omitImage: omitImage ?? this.omitImage,
    videoImageMode: clearVideoImageMode
        ? null
        : (videoImageMode ?? this.videoImageMode),
    coverFrameAtMs: clearCoverFrameAtMs
        ? null
        : (coverFrameAtMs ?? this.coverFrameAtMs),
    crop: clearCrop ? null : (crop ?? this.crop),
    mosaic: mosaic ?? this.mosaic,
    fieldValues: fieldValues ?? this.fieldValues,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (deckName != null) 'deck': deckName,
    if (omitAudio) 'omitAudio': true,
    if (audioStartDeltaMs != 0) 'audioStartDeltaMs': audioStartDeltaMs,
    if (audioEndDeltaMs != 0) 'audioEndDeltaMs': audioEndDeltaMs,
    if (audioSource != null) 'audioSource': audioSource,
    if (omitImage) 'omitImage': true,
    if (videoImageMode != null) 'videoImageMode': videoImageMode,
    if (coverFrameAtMs != null) 'coverFrameAtMs': coverFrameAtMs,
    if (crop != null) 'crop': crop!.toJson(),
    if (mosaic.isNotEmpty)
      'mosaic': <Map<String, Object?>>[
        for (final MiningMosaicRegion region in mosaic) region.toJson(),
      ],
    if (fieldValues.isNotEmpty) 'fields': fieldValues,
  };

  /// 解析 `fields`：只留「非空字符串键 → 非空白字符串值」，坏项逐个丢弃。
  static Map<String, String> _fieldValuesFromJson(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final Map<String, String> out = <String, String>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        if (e.key case final String name
            when name.isNotEmpty &&
                e.value is String &&
                (e.value! as String).trim().isNotEmpty)
          name: e.value! as String,
    };
    return out.isEmpty
        ? const <String, String>{}
        : Map<String, String>.unmodifiable(out);
  }

  static MiningRequestOverrides fromJson(Map<Object?, Object?> json) {
    final Object? deck = json['deck'];
    final Object? mode = json['videoImageMode'];
    final Object? frame = json['coverFrameAtMs'];
    final Object? start = json['audioStartDeltaMs'];
    final Object? end = json['audioEndDeltaMs'];
    final Object? source = json['audioSource'];
    return MiningRequestOverrides(
      deckName: deck is String && deck.trim().isNotEmpty ? deck : null,
      omitAudio: json['omitAudio'] == true,
      audioStartDeltaMs: start is num ? start.toInt() : 0,
      audioEndDeltaMs: end is num ? end.toInt() : 0,
      audioSource: source is String && source.isNotEmpty ? source : null,
      omitImage: json['omitImage'] == true,
      videoImageMode: mode is String && mode.isNotEmpty ? mode : null,
      coverFrameAtMs: frame is num ? frame.toInt() : null,
      crop: MiningImageCrop.fromJson(json['crop']),
      mosaic: MiningMosaicRegion.listFromJson(json['mosaic']),
      fieldValues: _fieldValuesFromJson(json['fields']),
    );
  }

  /// 把覆盖项拍进一份弹窗字段（全字符串线）。[overrides] 为空时原样返回，不留空键。
  static Map<String, String> attach(
    Map<String, String> fields,
    MiningRequestOverrides overrides,
  ) {
    if (overrides.isEmpty) return fields;
    return <String, String>{...fields, wireKey: jsonEncode(overrides.toJson())};
  }

  /// 从一份制卡字段里读出覆盖项（两条线都认：JSON 字符串或 Map）。没有 / 解析失败 →
  /// null（按普通一键制卡处理，不抛）。
  static MiningRequestOverrides? readFrom(Map<String, dynamic> fields) {
    final Object? raw = fields[wireKey];
    if (raw == null) return null;
    try {
      final Object? decoded = raw is String
          ? (raw.isEmpty ? null : jsonDecode(raw))
          : raw;
      if (decoded is! Map) return null;
      final MiningRequestOverrides o = fromJson(decoded);
      return o.isEmpty ? null : o;
    } catch (e, stack) {
      fushiDebugPrint('MiningRequestOverrides.readFrom: $e\n$stack');
      return null;
    }
  }
}
