import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/media_extensions.dart'
    show kAudioExtensions, kVideoExtensions;

/// sidecar 字幕的「无语言标记」基础扩展名优先级（查词主语言用的是带语言标记版）。
///
/// `.srt` > `.ass` > `.ssa` > `.vtt`。
const List<String> _baseSubtitleExtensions = <String>[
  '.srt',
  '.ass',
  '.ssa',
  '.vtt',
];

/// 按 app 目标学习语言为 [langCode] 构造 sidecar 字幕优先级后缀列表。
///
/// 规则：先找带语言标记 `.<langCode>.<ext>`（如学日语 → `.ja.srt`、`.ja.ass`…），
/// 再回退无语言标记 `.<ext>`（如 `.srt`、`.ass`…）。每组内格式优先级见
/// [_baseSubtitleExtensions]。
///
/// 例（langCode='ja'）：
/// `.ja.srt > .ja.ass > .ja.ssa > .ja.vtt > .srt > .ass > .ssa > .vtt`。
List<String> _sidecarSuffixPriority(String langCode) {
  final String lang = langCode.toLowerCase();
  final List<String> suffixes = <String>[];
  for (final String ext in _baseSubtitleExtensions) {
    suffixes.add('.$lang$ext');
  }
  suffixes.addAll(_baseSubtitleExtensions);
  return suffixes;
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

/// 纯函数：给「去掉视频扩展名的 basename」与「同目录文件名列表」，按 app 学习语言
/// [langCode] 的优先级挑出第一个匹配的 sidecar 字幕文件名；无则返回 null。
///
/// 优先级（以 langCode='ja' 为例）：
/// `.ja.srt > .ja.ass > .ja.ssa > .ja.vtt > .srt > .ass > .ssa > .vtt`，即先找
/// 带学习语言标记的同前缀字幕，再回退无语言标记的字幕。
///
/// 候选只取 [listSidecarSubtitles] 认给这个视频的（同目录 stem 更长的视频认领走的
/// 不算，见 [sidecarSubtitleOwnerStem]）；候选（不区分大小写比较）等于
/// `<videoBaseNameNoExt><suffix>`，suffix 取自 [_sidecarSuffixPriority]。返回的是
/// [dirFiles] 中的原始文件名（保留原始大小写），便于调用方直接拼回目录得到绝对路径。
///
/// 抽成纯函数是为可测：不碰文件系统，只做字符串优先级匹配。
String? pickSidecar(
  String videoBaseNameNoExt,
  List<String> dirFiles, {
  required String langCode,
}) {
  final List<String> mine = listSidecarSubtitles(videoBaseNameNoExt, dirFiles);
  if (mine.isEmpty) return null;
  final String baseLower = videoBaseNameNoExt.toLowerCase();
  for (final String suffix in _sidecarSuffixPriority(langCode)) {
    final String wantLower = '$baseLower$suffix';
    for (final String name in mine) {
      if (name.toLowerCase() == wantLower) {
        return name;
      }
    }
  }
  return null;
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

/// 纯函数：「设为该视频默认字幕」时落盘用的 sidecar 后缀——学习语言标记版
/// `.<langCode>.<ext>`（[pickSidecar] 优先级最高的那一组），[langCode] 为空时退回
/// 无标记 `.<ext>`。[format] 取 `srt` / `.ass` 等（大小写、前导点皆可）；不是字幕
/// 扩展名时返回 null。
String? defaultSidecarSubtitleSuffix(
  String format, {
  required String langCode,
}) {
  final String ext = format.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  if (!_baseSubtitleExtensions.contains('.$ext')) return null;
  final String lang = langCode.toLowerCase();
  final String suffix = lang.isEmpty ? '.$ext' : '.$lang.$ext';
  return isSidecarSubtitleSuffix(suffix) ? suffix : null;
}

/// 纯函数：把 [suffix] 落成默认字幕时要让位的 sidecar 后缀——[pickSidecar] 优先级
/// 列表里排在它前面的全部候选，加上它自己（同名文件会被覆盖）。不让位的话，一份
/// 更高优先级的旧字幕会继续被 host 选中，上传等于白传。[suffix] 不在优先级列表里
/// 时只返回它自己。
List<String> sidecarSuffixesDisplacedBy(
  String suffix, {
  required String langCode,
}) {
  final String lower = suffix.toLowerCase();
  final List<String> priority = langCode.isEmpty
      ? _baseSubtitleExtensions
      : _sidecarSuffixPriority(langCode);
  final int index = priority.indexOf(lower);
  if (index < 0) return <String>[lower];
  return priority.sublist(0, index + 1);
}

/// 在 [videoPath] 同目录查找同名 sidecar 字幕（IO 版，包装 [pickSidecar]）。
///
/// [langCode] 是 app 目标学习语言代码（如 `'ja'`/`'ko'`），优先选带该语言标记的
/// 字幕。返回第一个存在的字幕绝对路径（优先级见 [pickSidecar]），无则 null。
/// 目录不存在 / 读取失败时静默返回 null。
///
/// async：视频常在网络盘（rclone / SMB 挂载）上，同步 listSync 冷目录时要逐级重列
/// 目录、单次数秒，会冻结调用方整条 isolate——互联 host 跑在 app 主 isolate 上，
/// 一次字幕请求就能把全部端点和 UI 一起卡住（BUG-3756）。
Future<String?> findSidecarSubtitle(
  String videoPath, {
  required String langCode,
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

  final String? picked = pickSidecar(
    baseNameNoExt,
    dirFiles,
    langCode: langCode,
  );
  if (picked == null) return null;
  return p.normalize(p.join(dir, picked));
}

/// 外挂音轨的扩展名（小写、带点）：纯音频扩展名（[kAudioExtensions]，`.mka` / `.flac`
/// / `.ac3` …）加发布组常用的裸音轨扩展名。播放器发现本地外挂音轨
/// （[listSidecarAudioTracks]）与下载整理带走外挂件共用这一份。
const Set<String> kSidecarAudioExtraExtensions = <String>{
  '.dts',
  '.dtshd',
  '.thd',
  '.truehd',
};

/// 纯函数：扩展名 [extension]（带点，大小写不敏感）是不是外挂音轨扩展名。
bool isSidecarAudioExtension(String extension) {
  final String ext = extension.toLowerCase();
  return kAudioExtensions.contains(ext) ||
      kSidecarAudioExtraExtensions.contains(ext);
}

/// 视频旁的一条外挂音轨（[listSidecarAudioTracks] 的产物）。
typedef SidecarAudioTrack = ({
  /// 相对视频所在目录的路径（同目录就是文件名；子目录里是 `子目录/文件名`，`/` 分隔）。
  String relativePath,

  /// 文件名里主干之后、扩展名之前的标记（`ep01.jpn.mka` → `jpn`，
  /// `Movie_Eng_Audio_5.1.mka` → `Eng_Audio_5.1`）；没有为 null。
  String? tag,
});

/// 主干之后的外挂音轨后缀：`<分隔符><标记>.<ext>` 或 `.<ext>`，分隔符取 `.` / `_` / `-`
/// （与下载整理器配外挂件同一口径；`Movie_Eng_Audio_5.1.mka` 用的是 `_`）。标记里不许
/// 出现路径分隔符。返回标记（可能为 null）；不是外挂音轨后缀返回 `false` 记号。
({bool ok, String? tag}) _sidecarAudioSuffix(String rest) {
  // 前面垫一个字符：裸的 `.flac`（无标记）在 path 包眼里是点文件、扩展名为空。
  final String ext = p.extension('x$rest');
  if (ext.isEmpty || !isSidecarAudioExtension(ext)) {
    return (ok: false, tag: null);
  }
  final String middle = rest.substring(0, rest.length - ext.length);
  if (middle.isEmpty) return (ok: true, tag: null);
  if (!'._-'.contains(middle[0])) return (ok: false, tag: null);
  final String tag = middle.substring(1).trim();
  if (tag.isEmpty || tag.length > 64 || tag.contains(RegExp(r'[\/]'))) {
    return (ok: false, tag: null);
  }
  return (ok: true, tag: tag);
}

/// 纯函数：视频 `<videoBaseNameNoExt>` 旁的全部外挂音轨。
///
/// - 位置：与视频同目录（[dirFiles]），或视频目录的**直接子目录**（[childDirFiles]：
///   子目录名 → 其中文件名；`Audio 5.1/<主干>_Eng_Audio_5.1.mka`）。
/// - 文件名：不分大小写以视频主干开头，后面是 `.<ext>` 或 `<.|_|->标记.<ext>`，ext 是
///   外挂音轨扩展名（[isSidecarAudioExtension]）。
/// - 归属：同目录 stem 更长、且同样配得上这个文件的视频认领走（最长主干认领，与外挂
///   字幕 [listSidecarSubtitles] 同一条规则）。
/// - 纯数字主干（`01.mkv`）不认子目录里的文件：`CDs/01.flac` 这类专辑曲目与剧集同号
///   很常见，不是外挂音轨（同目录照常认，`01.mkv` 旁的 `01.flac` 就是它的音轨）。
///
/// 同目录的在前、子目录的在后，各自保持输入顺序。不碰文件系统。
List<SidecarAudioTrack> listSidecarAudioTracks(
  String videoBaseNameNoExt,
  List<String> dirFiles, {
  Map<String, List<String>> childDirFiles = const <String, List<String>>{},
}) {
  final String stemLower = videoBaseNameNoExt.toLowerCase();
  if (stemLower.isEmpty) return const <SidecarAudioTrack>[];
  // 同目录里 stem 更长、以本 stem 开头的视频：可能把候选认领走。
  final List<String> longerStems = <String>[
    for (final String name in dirFiles)
      if (kVideoExtensions.contains(p.extension(name).toLowerCase()))
        if (p.basenameWithoutExtension(name).toLowerCase() case final String s
            when s.length > stemLower.length && s.startsWith(stemLower))
          s,
  ];
  ({bool ok, String? tag}) match(String name) {
    final String lower = name.toLowerCase();
    if (lower.length <= stemLower.length || !lower.startsWith(stemLower)) {
      return (ok: false, tag: null);
    }
    final ({bool ok, String? tag}) mine = _sidecarAudioSuffix(
      name.substring(videoBaseNameNoExt.length),
    );
    if (!mine.ok) return mine;
    for (final String longer in longerStems) {
      if (lower.startsWith(longer) &&
          lower.length > longer.length &&
          _sidecarAudioSuffix(name.substring(longer.length)).ok) {
        return (ok: false, tag: null);
      }
    }
    return mine;
  }

  final List<SidecarAudioTrack> out = <SidecarAudioTrack>[
    for (final String name in dirFiles)
      if (match(name) case (ok: true, tag: final String? tag))
        (relativePath: name, tag: tag),
  ];
  if (RegExp(r'^\d+$').hasMatch(videoBaseNameNoExt)) return out;
  for (final MapEntry<String, List<String>> child in childDirFiles.entries) {
    for (final String name in child.value) {
      if (match(name) case (ok: true, tag: final String? tag)) {
        out.add((relativePath: '${child.key}/$name', tag: tag));
      }
    }
  }
  return out;
}

/// 纯函数：外挂音轨标记 [tag] 给人看的名字与语言码。名字 = 标记里的 `_` 换成空格；
/// 标记的第一段（按 `.` / `_` / `-` / 空格切）是 2–3 个字母时当语言码（小写，
/// `jpn` / `eng` / `ja`），否则没有语言。没有标记时名字用文件名（[fileName]）。
({String label, String? language}) sidecarAudioLabel(
  String? tag,
  String fileName,
) {
  if (tag == null || tag.trim().isEmpty) {
    return (label: fileName, language: null);
  }
  final String first = tag.split(RegExp(r'[._\- ]')).first;
  return (
    label: tag.replaceAll('_', ' ').trim(),
    language: RegExp(r'^[A-Za-z]{2,3}$').hasMatch(first)
        ? first.toLowerCase()
        : null,
  );
}
