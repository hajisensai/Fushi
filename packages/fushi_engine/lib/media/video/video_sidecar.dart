import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart' show readTextWithEncoding;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/media_extensions.dart' show kVideoExtensions;
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_target.dart';

/// sidecar 字幕的基础扩展名优先级：`.srt` > `.ass` > `.ssa` > `.vtt`（同一语言档内的
/// 次序键）。
const List<String> _baseSubtitleExtensions = <String>[
  '.srt',
  '.ass',
  '.ssa',
  '.vtt',
];

int _formatRank(String name) {
  final int i = _baseSubtitleExtensions.indexOf(
    p.extension(name).toLowerCase(),
  );
  return i < 0 ? _baseSubtitleExtensions.length : i;
}

/// 语言未知时用来判「这些带标记的字幕是不是同一种语言」的键（中文繁 / 简算两种）；
/// 标记不是语言写法（`forced` / `sdh`）返回 null。
String? _sidecarLanguageKey(String tag) {
  final String? code = subtitleTokenLanguageCode(tag);
  if (code == null) return null;
  final ChineseScript? script = code == 'zh'
      ? chineseScriptOfLanguageTag(tag)
      : null;
  return script == null ? code : '$code-${script.name}';
}

/// 一条 sidecar 的排名档（越小越先）；null = 不自动加载。规则见 [rankSidecarSubtitles]。
int? _sidecarTier({
  required String? tag,
  required SubtitleLanguageTarget? target,
  required ChineseScript? contentScript,
  required bool singleTaggedLanguage,
}) {
  if (target == null) {
    if (tag == null) return 0;
    if (_sidecarLanguageKey(tag) == null) return null;
    return singleTaggedLanguage ? 1 : null;
  }
  if (tag == null) {
    final ChineseScript? want = target.script;
    if (target.code == 'zh' && want != null && contentScript != null) {
      return contentScript == want ? 0 : 3;
    }
    return 2;
  }
  return switch (matchSubtitleTarget(
    target,
    languageTag: tag,
    contentScript: contentScript,
  )) {
    SubtitleTargetMatch.exact => 0,
    SubtitleTargetMatch.scriptUnknown => 1,
    SubtitleTargetMatch.otherScript => 3,
    SubtitleTargetMatch.none => null,
  };
}

/// 纯函数：把属于 `<videoBaseNameNoExt>` 的 sidecar [candidates]（[listSidecarSubtitles]
/// 的结果）按目标语言 [langCode] 排成自动加载的先后；**不该自动加载的不在结果里**。
///
/// [langCode] 是语言标签（`ja` / `zh-Hant` / `ko-KR` …，[SubtitleLanguageTarget.parse]
/// 能认的写法），空串 = 语言未知。语言标记按语言比较而不是按字面：`.jpn.srt`、
/// `.ja-JP.srt`、`.japanese.srt` 都算日语，`.chs` / `.sc` / `.zh-Hans` 都算简体中文。
///
/// 档次（目标已知）：
/// 0. 标记的语言对上（中文还要繁 / 简对上；无标记但正文判出同一书写系统的也在这档，
///    排在带标记的后面）；
/// 1. 标了中文但没标繁 / 简（目标是带书写系统的中文时）；
/// 2. 无语言标记（可能就是本片语言，旧行为里它也排在语言标记组之后）；
/// 3. 同为中文但书写系统相反（读得懂，最后才用）；
/// 标了别的语言（`.en.srt` 之于日语片）与标记不是语言写法（`.forced.srt`）的不自动加载。
///
/// 目标未知时**不猜**：无标记的先；带标记的只在它们全是同一种语言时才用（没得选
/// 也就无所谓猜）；混着几种语言就都不自动加载。
///
/// 同档内：带标记的先于无标记的、`.srt` > `.ass` > `.ssa` > `.vtt`、再按文件名。
/// [contentScripts] 是读正文判出的繁 / 简（见 [sidecarSubtitlesNeedingScriptSniff]），
/// 键为候选原名。
List<String> rankSidecarSubtitles(
  String videoBaseNameNoExt,
  List<String> candidates, {
  required String langCode,
  Map<String, ChineseScript> contentScripts = const <String, ChineseScript>{},
}) {
  final SubtitleLanguageTarget? target = SubtitleLanguageTarget.parse(langCode);
  final Set<String> taggedLanguages = <String>{
    for (final String name in candidates)
      if (sidecarSubtitleLanguageTag(videoBaseNameNoExt, name)
          case final String t)
        if (_sidecarLanguageKey(t) case final String key) key,
  };
  final List<({String name, int tier, int tagged, int format})> ranked =
      <({String name, int tier, int tagged, int format})>[];
  for (final String name in candidates) {
    final String? tag = sidecarSubtitleLanguageTag(videoBaseNameNoExt, name);
    final int? tier = _sidecarTier(
      tag: tag,
      target: target,
      contentScript: contentScripts[name],
      singleTaggedLanguage: taggedLanguages.length == 1,
    );
    if (tier == null) continue;
    ranked.add((
      name: name,
      tier: tier,
      tagged: tag == null ? 1 : 0,
      format: _formatRank(name),
    ));
  }
  ranked.sort((a, b) {
    int c = a.tier.compareTo(b.tier);
    if (c != 0) return c;
    c = a.tagged.compareTo(b.tagged);
    if (c != 0) return c;
    c = a.format.compareTo(b.format);
    if (c != 0) return c;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return <String>[for (final r in ranked) r.name];
}

/// 纯函数：目标是带书写系统的中文（`zh-Hant` / `zh-Hans`）、而 [candidates] 里没有
/// 一条靠标记就对上书写系统时，需要读正文判繁 / 简的候选（无标记的、只标了中文没标
/// 繁简的）。其余情况返回空表——标记已经够用，不读盘。
List<String> sidecarSubtitlesNeedingScriptSniff(
  String videoBaseNameNoExt,
  List<String> candidates, {
  required String langCode,
}) {
  final SubtitleLanguageTarget? target = SubtitleLanguageTarget.parse(langCode);
  if (target == null || target.code != 'zh' || target.script == null) {
    return const <String>[];
  }
  final List<String> ambiguous = <String>[];
  for (final String name in candidates) {
    final String? tag = sidecarSubtitleLanguageTag(videoBaseNameNoExt, name);
    if (tag == null) {
      ambiguous.add(name);
      continue;
    }
    switch (matchSubtitleTarget(target, languageTag: tag)) {
      case SubtitleTargetMatch.exact:
        return const <String>[];
      case SubtitleTargetMatch.scriptUnknown:
        ambiguous.add(name);
      case SubtitleTargetMatch.otherScript || SubtitleTargetMatch.none:
        break;
    }
  }
  return ambiguous;
}

/// 外挂字幕的归属规则（三处共用：播放器选 / 列字幕、删视频带走字幕、iOS 收件箱搬入
/// 配对；拍板台 review-hbk-audit-220-player-sub-owner）：**最长文件名主干认领字幕**。
///
/// 字幕 `<stem>[.lang].srt|ass|ssa|vtt` 按前缀配对，同目录两个视频的 stem 互为前缀时
/// （`EP01.mkv` 与 `EP01.ja.mkv`、`ep01.mkv` 与 `ep01.5.mkv`），`EP01.ja.srt` 字面上对
/// 两边都成立（对 `EP01` 而言 `.ja` 像语言标记）。它只归能配上它的 stem 里**最长**的
/// 那个：`EP01.ja.srt` 是 `EP01.ja.mkv` 的字幕，不再被 `EP01.mkv` 当日语轨选上。
///
/// 纯函数：字幕文件名 [subtitleName] 在同目录主文件 stem [ownerStems] 里归谁——能配上它
/// 的**最长** stem（不分大小写比较，返回 [ownerStems] 里的原样写法；等长并列取先出现
/// 的），一个都配不上返回 null。
String? sidecarSubtitleOwnerStem(
  String subtitleName,
  Iterable<String> ownerStems,
) {
  String? owner;
  for (final String stem in ownerStems) {
    if (owner != null && stem.length <= owner.length) continue;
    if (_isRawSidecarOf(stem.toLowerCase(), subtitleName)) owner = stem;
  }
  return owner;
}

/// 字面配对：[name] 是否是 `<stemLower><可选语言标记><字幕扩展名>`（不看同目录别的
/// 视频；归属请走 [sidecarSubtitleOwnerStem] / [listSidecarSubtitles]）。
bool _isRawSidecarOf(String stemLower, String name) =>
    stemLower.isNotEmpty &&
    name.length > stemLower.length &&
    name.toLowerCase().startsWith(stemLower) &&
    isSidecarSubtitleSuffix(name.substring(stemLower.length));

/// 纯函数：给「去掉视频扩展名的 basename」与「同目录文件名列表」，按目标语言
/// [langCode]（语言标签，空串 = 未知）挑出最该自动加载的 sidecar 字幕文件名；无则
/// 返回 null。排序规则见 [rankSidecarSubtitles]。
///
/// 候选只取 [listSidecarSubtitles] 认给这个视频的（同目录 stem 更长的视频认领走的
/// 不算，见 [sidecarSubtitleOwnerStem]）。返回的是 [dirFiles] 中的原始文件名（保留
/// 原始大小写），便于调用方直接拼回目录得到绝对路径。
///
/// 抽成纯函数是为可测：不碰文件系统。
String? pickSidecar(
  String videoBaseNameNoExt,
  List<String> dirFiles, {
  required String langCode,
  Map<String, ChineseScript> contentScripts = const <String, ChineseScript>{},
}) {
  final List<String> mine = listSidecarSubtitles(videoBaseNameNoExt, dirFiles);
  if (mine.isEmpty) return null;
  final List<String> ranked = rankSidecarSubtitles(
    videoBaseNameNoExt,
    mine,
    langCode: langCode,
    contentScripts: contentScripts,
  );
  return ranked.isEmpty ? null : ranked.first;
}

/// 纯函数：列出 [dirFiles] 中**所有**属于 `<videoBaseNameNoExt>` 的 sidecar 字幕
/// 文件名（不区分大小写匹配，返回原始文件名，保持 [dirFiles] 顺序）。
///
/// 匹配规则：`<stem><suffix>`，suffix 为可选语言标记 + 字幕扩展名
/// （`.srt` / `.ja.srt` / `.zh-Hans.ass` …），再按「最长主干认领」去掉同目录 stem
/// 更长的视频文件（[kVideoExtensions]）认领的那些（[sidecarSubtitleOwnerStem]）。
/// 与 [pickSidecar] 的按语言挑选互补——互联 live push 用它把视频的全部外挂字幕推给
/// host（BUG-964），host 端再按自己的学习语言用 [pickSidecar] 解析首选，不在传输层
/// 替对端做语言决策；删视频带走字幕（`sidecarSubtitlesForDeletedVideo`）也是它。
List<String> listSidecarSubtitles(
  String videoBaseNameNoExt,
  List<String> dirFiles,
) {
  final String baseLower = videoBaseNameNoExt.toLowerCase();
  final List<String> raw = <String>[
    for (final String name in dirFiles)
      if (_isRawSidecarOf(baseLower, name)) name,
  ];
  if (raw.isEmpty) return raw;
  // 只有 stem 更长且以本 stem 开头的视频才可能抢走本 stem 的候选。
  final List<String> longerVideoStems = <String>[
    for (final String name in dirFiles)
      if (kVideoExtensions.contains(p.extension(name).toLowerCase()))
        if (p.basenameWithoutExtension(name) case final String stem
            when stem.length > baseLower.length &&
                stem.toLowerCase().startsWith(baseLower))
          stem,
  ];
  if (longerVideoStems.isEmpty) return raw;
  return <String>[
    for (final String name in raw)
      if (sidecarSubtitleOwnerStem(name, longerVideoStems) == null) name,
  ];
}

/// 纯函数：写入端的同一条「最长主干认领」——给 `<videoBaseNameNoExt>` 落一份后缀
/// [suffix] 的外挂字幕时，实际该用的后缀。
///
/// `<stem><suffix>` 会被同目录 stem 更长的视频认领时（`EP01.mkv` 旁有 `EP01.ja.mkv`，
/// 给 `EP01` 落 `.ja.srt` 得到的 `EP01.ja.srt` 归 `EP01.ja.mkv`），照原名写既让本视频
/// 看不到这份字幕（[pickSidecar] / [listSidecarSubtitles] 不认），又会盖掉 / 冒充别的
/// 视频的字幕；这时退回无语言标记的 `.<ext>`——`<stem>.<ext>` 恒归本视频（更长的
/// stem 后面剩不下一个合法的 `.<ext>` 后缀）。[dirFiles] 是同目录文件名清单。
/// [suffix] 不是合法 sidecar 后缀（[isSidecarSubtitleSuffix]）时原样返回，由调用方
/// 自己的校验处理。
String ownedSidecarSuffix(
  String videoBaseNameNoExt,
  String suffix,
  List<String> dirFiles,
) {
  if (!isSidecarSubtitleSuffix(suffix)) return suffix;
  final String name = '$videoBaseNameNoExt$suffix';
  final String nameLower = name.toLowerCase();
  final bool owned = listSidecarSubtitles(videoBaseNameNoExt, <String>[
    ...dirFiles,
    name,
  ]).any((String n) => n.toLowerCase() == nameLower);
  if (owned) return suffix;
  return suffix.substring(suffix.lastIndexOf('.'));
}

/// 纯函数：[suffix] 是否是合法的 sidecar 字幕后缀（`.<ext>` 或 `.<langTag>.<ext>`，
/// ext ∈ srt/ass/ssa/vtt，langTag 只允许 `[A-Za-z0-9_-]`）。互联字幕上传端点用它做
/// 服务端白名单校验（后缀由 client 报，绝不放行路径分隔符/穿越）。
bool isSidecarSubtitleSuffix(String suffix) => RegExp(
  r'^(\.[A-Za-z0-9_-]{1,32})?\.(srt|ass|ssa|vtt)$',
  caseSensitive: false,
).hasMatch(suffix);

/// 纯函数：sidecar 字幕文件名 [fileName] 里的语言标记（`<stem>.<tag>.<ext>` 的
/// `<tag>`，原样大小写）。不是 [videoBaseNameNoExt] 的 sidecar、或没有标记
/// （`<stem>.srt`）时返回 null。互联 host 列全部外挂字幕时给每条报语言（反馈
/// -CaVsioFhG）。
String? sidecarSubtitleLanguageTag(String videoBaseNameNoExt, String fileName) {
  final int stemLength = videoBaseNameNoExt.length;
  if (fileName.length <= stemLength ||
      !fileName.toLowerCase().startsWith(videoBaseNameNoExt.toLowerCase())) {
    return null;
  }
  final String suffix = fileName.substring(stemLength);
  if (!isSidecarSubtitleSuffix(suffix)) return null;
  final List<String> parts = suffix.split('.');
  // `.ja.srt` → ['', 'ja', 'srt']；`.srt` → ['', 'srt']。
  return parts.length == 3 ? parts[1] : null;
}

/// 纯函数：「设为该视频默认字幕」时落盘用的 sidecar 后缀——目标语言标记版
/// `.<规范标签>.<ext>`（`.ja.srt` / `.zh-Hant.ass`，[rankSidecarSubtitles] 最先的
/// 那一档），[langCode] 为空或认不出语言时退回无标记 `.<ext>`。[format] 取 `srt` /
/// `.ass` 等（大小写、前导点皆可）；不是字幕扩展名时返回 null。
String? defaultSidecarSubtitleSuffix(
  String format, {
  required String langCode,
}) {
  final String ext = format.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  if (!_baseSubtitleExtensions.contains('.$ext')) return null;
  final String lang = SubtitleLanguageTarget.parse(langCode)?.tag ?? '';
  final String suffix = lang.isEmpty ? '.$ext' : '.$lang.$ext';
  return isSidecarSubtitleSuffix(suffix) ? suffix : null;
}

/// 纯函数：把 `<videoBaseNameNoExt><placedSuffix>` 落成默认字幕时要让位的 sidecar
/// （小写文件名）——[ownedNames]（归这个视频的现有 sidecar）里按 [rankSidecarSubtitles]
/// 排在它前面或与它并列靠前的全部，加上同名的它自己（会被覆盖）。不让位的话，一份
/// 排得更前的旧字幕会继续被选中，上传等于白传。落下的这份本身不会被自动加载时
/// （语言对不上）只让位同名文件。
Set<String> sidecarNamesDisplacedBy(
  String videoBaseNameNoExt,
  String placedSuffix,
  List<String> ownedNames, {
  required String langCode,
}) {
  final String placedLower = '$videoBaseNameNoExt$placedSuffix'.toLowerCase();
  final List<String> pool = <String>[
    for (final String n in ownedNames)
      if (n.toLowerCase() != placedLower) n,
    '$videoBaseNameNoExt$placedSuffix',
  ];
  final List<String> ranked = rankSidecarSubtitles(
    videoBaseNameNoExt,
    pool,
    langCode: langCode,
  );
  final int index = ranked.indexWhere(
    (String n) => n.toLowerCase() == placedLower,
  );
  return <String>{
    placedLower,
    if (index > 0)
      for (final String n in ranked.sublist(0, index)) n.toLowerCase(),
  };
}

/// 在 [videoPath] 同目录查找同名 sidecar 字幕（IO 版，包装 [pickSidecar]）。
///
/// [langCode] 是本视频的目标语言标签（见 [rankSidecarSubtitles]；空串 = 未知）。
/// 目标是带书写系统的中文、而标记分不出繁简时，读那几份候选的正文判繁简
/// （[sidecarSubtitlesNeedingScriptSniff]，字幕文件只有几十 KB）。返回字幕绝对路径，
/// 无则 null。目录不存在 / 读取失败时静默返回 null。
///
/// [fallbackLanguage]：[langCode] 为空、而带标记的候选混着几种语言（不猜就挑不出）
/// 时才调一次，取最后一条证据（播放页传音轨语言，见 `audioSubtitleLanguageTarget`）；
/// 其余情况不调——它可能要起一次 ffmpeg。
///
/// async：视频常在网络盘（rclone / SMB 挂载）上，同步 listSync 冷目录时要逐级重列
/// 目录、单次数秒，会冻结调用方整条 isolate——互联 host 跑在 app 主 isolate 上，
/// 一次字幕请求就能把全部端点和 UI 一起卡住（BUG-3756）。
Future<String?> findSidecarSubtitle(
  String videoPath, {
  required String langCode,
  Future<String> Function()? fallbackLanguage,
}) async {
  final String dir = p.dirname(videoPath);
  final String baseNameNoExt = p.basenameWithoutExtension(videoPath);

  final List<String> dirFiles = <String>[];
  try {
    await for (final FileSystemEntity e in Directory(
      dir,
    ).list(followLinks: false)) {
      if (e is File) dirFiles.add(p.basename(e.path));
    }
  } on FileSystemException {
    // 目录不存在 / 无权限：与旧实现一致，静默返回 null。
    return null;
  }

  final List<String> mine = listSidecarSubtitles(baseNameNoExt, dirFiles);
  if (mine.isEmpty) return null;
  final String? picked = await _pickSidecarWithSniff(
    dir,
    baseNameNoExt,
    mine,
    langCode,
  );
  if (picked != null) return p.normalize(p.join(dir, picked));
  if (langCode.trim().isNotEmpty || fallbackLanguage == null) return null;
  final String fallback = (await fallbackLanguage()).trim();
  if (fallback.isEmpty) return null;
  final String? byFallback = await _pickSidecarWithSniff(
    dir,
    baseNameNoExt,
    mine,
    fallback,
  );
  return byFallback == null ? null : p.normalize(p.join(dir, byFallback));
}

Future<String?> _pickSidecarWithSniff(
  String dir,
  String baseNameNoExt,
  List<String> mine,
  String langCode,
) async {
  final Map<String, ChineseScript> contentScripts = <String, ChineseScript>{};
  for (final String name in sidecarSubtitlesNeedingScriptSniff(
    baseNameNoExt,
    mine,
    langCode: langCode,
  )) {
    final ChineseScript? script = await _sniffChineseScript(
      File(p.join(dir, name)),
    );
    if (script != null) contentScripts[name] = script;
  }
  final List<String> ranked = rankSidecarSubtitles(
    baseNameNoExt,
    mine,
    langCode: langCode,
    contentScripts: contentScripts,
  );
  return ranked.isEmpty ? null : ranked.first;
}

/// 读一份字幕的正文判繁 / 简（[detectSubtitleContentLanguage]）；不是单一书写系统
/// 的中文、或读不出时返回 null。
Future<ChineseScript?> _sniffChineseScript(File file) async {
  try {
    return switch (detectSubtitleContentLanguage(
      await readTextWithEncoding(file),
    )) {
      SubtitleContentLanguage.simplifiedChinese => ChineseScript.simplified,
      SubtitleContentLanguage.traditionalChinese => ChineseScript.traditional,
      _ => null,
    };
  } on FileSystemException {
    return null;
  }
}
