/// 书架文件夹导入时「书 ↔ 有声书音频 / 字幕」的配对规则（纯函数，无 IO）。
///
/// 书旁同名 sidecar（规则 R1，`selectSidecarNames`）住在 app 侧的
/// `sidecar_finder.dart`，由来源扫描器先跑；本文件只负责 R1 没配上的书和 R1 没认领
/// 的音频，按优先级逐条试：
///
/// - **R2 同名子目录**：书 `D/X.epub` 配 `D/X/`（`foldMediaTitle` 相等），子目录下的
///   分碟目录（`D/X/CD1`、`D/X/Disc 2`）并进来；
/// - **R3 卷号**：多卷书（`parseBookSeriesKey` 解出系列键 + 卷号）配同系列同卷号的
///   音频单元，或子目录名只有卷号（`Vol.1/`、`01/`，`parseBookVolumeFolderName`）。
///   一个系列组里每个单元必须恰好对上一本书、每本书至多一个单元，否则整组放弃；
/// - **R4 独卷目录**：D 里恰好一本非 PDF 的书时，D 这一层未被认领的音频（散放的 +
///   D 下分碟目录里的）全部给它。
///
/// R5（按 EPUB `dc:title` 配）要先导入才知道标题，由扫描器在全部书导入后统一调一次
/// [pairByBookTitles]。
///
/// 冲突一律放弃（宁可漏配）：同一个音频文件被两本以上的书认领时，这些书都不配，
/// 进 [BookAudiobookPairingPlan.ambiguousBookPaths]。
///
/// 路径只做字符串运算，按 [p.Context] 解释（网络来源传 `p.url`），原样保留输入写法。
library;

import 'package:fushi_audio/fushi_audio.dart' show compareAudioFilePath;
import 'package:fushi_core/fushi_core.dart' show foldMediaTitle;
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_pick.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:path/path.dart' as p;

/// 分碟子目录（`CD1` / `Disc 2` / `Disk_03` / `Part 1`）：并进上一层算同一本。
/// 书架配对与无头服务端的有声书库划分共用这一条判据。
final RegExp _discFolderPattern = RegExp(
  r'^(cd|disc|disk|part)[\s_\-]*\d+$',
  caseSensitive: false,
);

/// 目录名 [name] 是不是分碟子目录（见 [_discFolderPattern]）。
bool isAudiobookDiscFolderName(String name) =>
    _discFolderPattern.hasMatch(name.trim());

/// 配上的依据。
enum BookAudiobookPairRule { sameName, subFolder, volume, soleBook, metadata }

/// 一本书配上的有声书素材。
class BookAudiobookPairing {
  const BookAudiobookPairing({
    required this.bookPath,
    required this.subtitlePath,
    required this.audioPaths,
    required this.rule,
  });

  final String bookPath;

  /// 选中的字幕；null = 有音频没字幕（交给转录 / 计入缺字幕）。
  final String? subtitlePath;

  /// 按播放顺序排好的音频（分碟目录先按目录自然序，再按文件自然序）。
  final List<String> audioPaths;
  final BookAudiobookPairRule rule;

  @override
  bool operator ==(Object other) =>
      other is BookAudiobookPairing &&
      other.bookPath == bookPath &&
      other.subtitlePath == subtitlePath &&
      other.rule == rule &&
      _sameList(other.audioPaths, audioPaths);

  @override
  int get hashCode =>
      Object.hash(bookPath, subtitlePath, rule, Object.hashAll(audioPaths));

  @override
  String toString() =>
      'BookAudiobookPairing($bookPath, $rule, sub=$subtitlePath, '
      'audio=$audioPaths)';
}

/// 一个有声书音频单元：一个子目录（含它下面的分碟目录），或某层目录里散放的一个
/// 音频文件，或某层目录下分碟目录的合集。
class AudiobookUnit {
  const AudiobookUnit({
    required this.path,
    required this.scopeDir,
    required this.title,
    required this.audioPaths,
    required this.subtitlePaths,
  });

  /// 单元身份：子目录 / 散放文件的路径；某层分碟合集为那一层目录本身。
  final String path;

  /// 哪个目录里的书可以认领它（子目录单元 = 父目录；散放文件 / 分碟合集 = 所在层）。
  final String scopeDir;

  /// 比对用的名字：目录名或文件主干。
  final String title;
  final List<String> audioPaths;

  /// 单元内的字幕（子目录单元 = 目录及其分碟目录里的全部；散放 / 分碟合集 = 与某条
  /// 音频同主干的，加分碟目录里的）。
  final List<String> subtitlePaths;

  @override
  String toString() => 'AudiobookUnit($path, title=$title, audio=$audioPaths)';
}

class BookAudiobookPairingPlan {
  const BookAudiobookPairingPlan({
    required this.byBook,
    required this.unclaimedUnits,
    required this.ambiguousBookPaths,
  });

  /// 书路径 → 配对结果（只含 R2–R4 配上的）。
  final Map<String, BookAudiobookPairing> byBook;

  /// 没有任何音频被认领的单元（留给 R5）。
  final List<AudiobookUnit> unclaimedUnits;

  /// 因冲突放弃配对的书（已排序）。
  final List<String> ambiguousBookPaths;
}

/// 文件夹导入的有声书转录端口结果。
enum BookAudiobookTranscribeResult {
  /// 新排进了转录队列。
  queued,

  /// 这组音频已有转录任务（含已结束的失败 / 取消任务，由用户在下载中心重试）。
  alreadyTracked,
}

/// 扫描器把「有音频没字幕」的书交给转录队列的端口（挂到已导入的 [bookKey] 上）。
typedef BookAudiobookTranscribePort =
    Future<BookAudiobookTranscribeResult> Function({
      required String bookKey,
      required List<String> audioPaths,
      required String title,
    });

/// R2–R4。
///
/// - [unpairedBookPaths]：R1 没配上音频的非 PDF 书；
/// - [pairedBookPaths]：R1 已配上音频的非 PDF 书（只参与 R4 的「恰好一本」计数）；
/// - [unclaimedAudioPaths]：R1 没认领的音频（调用方已按 sidecar 音频口径过滤）；
/// - [subtitlePaths]：来源里全部有声书字幕；
/// - [subtitleLangCode]：学习语言，交给 [pickAudiobookSubtitle]。
BookAudiobookPairingPlan pairBooksWithAudiobooks({
  required List<String> unpairedBookPaths,
  List<String> pairedBookPaths = const <String>[],
  required List<String> unclaimedAudioPaths,
  required List<String> subtitlePaths,
  required String subtitleLangCode,
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  final _UnitIndex index = _UnitIndex.build(
    audioPaths: unclaimedAudioPaths,
    subtitlePaths: subtitlePaths,
    ctx: ctx,
  );
  final List<String> books = <String>[...unpairedBookPaths]..sort();
  final Map<String, int> booksPerDir = <String, int>{};
  for (final String book in <String>{...books, ...pairedBookPaths}) {
    final String dir = ctx.dirname(book);
    booksPerDir[dir] = (booksPerDir[dir] ?? 0) + 1;
  }

  final Map<String, _Claim> claims = <String, _Claim>{};
  final Set<String> ambiguous = <String>{};

  bool decided(String book) =>
      claims.containsKey(book) || ambiguous.contains(book);

  // R2：同名子目录。同名的子目录不止一个（大小写不同的两个目录）→ 歧义。
  for (final String book in books) {
    final String folded = foldMediaTitle(ctx.basenameWithoutExtension(book));
    if (folded.isEmpty) continue;
    final List<AudiobookUnit> sameName = <AudiobookUnit>[
      for (final AudiobookUnit unit in index.childUnitsOf(ctx.dirname(book)))
        if (foldMediaTitle(unit.title) == folded) unit,
    ];
    if (sameName.length > 1) {
      ambiguous.add(book);
    } else if (sameName.length == 1) {
      claims[book] = _Claim(
        units: sameName,
        rule: BookAudiobookPairRule.subFolder,
      );
    }
  }

  // R3：卷号。按目录 + 系列整组算（R2 已认领的单元不再参与），组内不能一一对应时
  // 整组放弃。
  final Set<AudiobookUnit> r2Units = Set<AudiobookUnit>.identity()
    ..addAll(<AudiobookUnit>[
      for (final _Claim claim in claims.values) ...claim.units,
    ]);
  claims.addAll(
    _volumeClaims(
      books: <String>[
        for (final String book in books)
          if (!decided(book)) book,
      ],
      index: index,
      excludedUnits: r2Units,
      ctx: ctx,
      ambiguous: ambiguous,
    ),
  );

  for (final String book in books) {
    if (decided(book)) continue;
    final String dir = ctx.dirname(book);
    // R4：D 里恰好一本非 PDF 的书。
    if (booksPerDir[dir] == 1) {
      final List<AudiobookUnit> level = index.levelUnitsOf(dir);
      if (level.isNotEmpty) {
        claims[book] = _Claim(
          units: level,
          rule: BookAudiobookPairRule.soleBook,
        );
      }
    }
  }

  // 文件级冲突：一个音频被两本以上的书认领 → 这些书都不配。
  final Map<String, Set<String>> claimantsByAudio = <String, Set<String>>{};
  claims.forEach((String book, _Claim claim) {
    for (final AudiobookUnit unit in claim.units) {
      for (final String audio in unit.audioPaths) {
        (claimantsByAudio[audio] ??= <String>{}).add(book);
      }
    }
  });
  for (final Set<String> claimants in claimantsByAudio.values) {
    if (claimants.length > 1) ambiguous.addAll(claimants);
  }

  final Map<String, BookAudiobookPairing> byBook =
      <String, BookAudiobookPairing>{};
  final Set<String> claimedAudio = <String>{};
  for (final String book in books) {
    final _Claim? claim = claims[book];
    if (claim == null) continue;
    // 歧义书认领过的音频同样不再留给 R5：它们是有争议的，不是没人要的。
    for (final AudiobookUnit unit in claim.units) {
      claimedAudio.addAll(unit.audioPaths);
    }
    if (ambiguous.contains(book)) continue;
    byBook[book] = _pairingOf(
      book: book,
      units: claim.units,
      rule: claim.rule,
      bookStemSubtitles: index.subtitlesWithStemIn(
        ctx.dirname(book),
        ctx.basenameWithoutExtension(book),
      ),
      subtitleLangCode: subtitleLangCode,
      title: ctx.basenameWithoutExtension(book),
    );
  }

  return BookAudiobookPairingPlan(
    byBook: byBook,
    unclaimedUnits: <AudiobookUnit>[
      for (final AudiobookUnit unit in index.allUnits)
        if (!unit.audioPaths.any(claimedAudio.contains)) unit,
    ],
    ambiguousBookPaths: ambiguous.toList()..sort(),
  );
}

/// R5：按书的元数据标题（[titleByBookPath]，书路径 → `dc:title`）配 [unclaimed]
/// 里同目录的单元，`foldMediaTitle` 精确相等才算。一次性批量处理：一本书对上多个
/// 单元、或一个单元被多本书对上，相关的书全部放弃。结果与输入顺序无关。
///
/// [subtitlePaths]：来源里全部字幕，用来补「书所在目录里与书同主干的字幕」。
Map<String, BookAudiobookPairing> pairByBookTitles({
  required Map<String, String> titleByBookPath,
  required List<AudiobookUnit> unclaimed,
  List<String> subtitlePaths = const <String>[],
  required String subtitleLangCode,
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  final List<String> books = titleByBookPath.keys.toList()..sort();
  final Map<String, List<AudiobookUnit>> matches =
      <String, List<AudiobookUnit>>{};
  // 冲突按音频文件算：父目录的书对上子目录单元、子目录里的书对上同一批音频的层单元，
  // 单元身份不同但音频相同，同样是两本书抢一份音频。
  final Map<String, Set<String>> booksByAudio = <String, Set<String>>{};
  for (final String book in books) {
    final String folded = foldMediaTitle(titleByBookPath[book]!);
    if (folded.isEmpty) continue;
    final String dir = ctx.dirname(book);
    final List<AudiobookUnit> hits = <AudiobookUnit>[
      for (final AudiobookUnit unit in unclaimed)
        if (ctx.equals(unit.scopeDir, dir) &&
            foldMediaTitle(unit.title) == folded)
          unit,
    ];
    if (hits.isEmpty) continue;
    matches[book] = hits;
    for (final AudiobookUnit unit in hits) {
      for (final String audio in unit.audioPaths) {
        (booksByAudio[audio] ??= <String>{}).add(book);
      }
    }
  }
  final Map<String, BookAudiobookPairing> out =
      <String, BookAudiobookPairing>{};
  for (final String book in books) {
    final List<AudiobookUnit>? hits = matches[book];
    if (hits == null || hits.length != 1) continue;
    if (hits.single.audioPaths.any(
      (String audio) => booksByAudio[audio]!.length != 1,
    )) {
      continue;
    }
    final String dir = ctx.dirname(book);
    final String stem = ctx.basenameWithoutExtension(book);
    out[book] = _pairingOf(
      book: book,
      units: hits,
      rule: BookAudiobookPairRule.metadata,
      bookStemSubtitles: <String>[
        for (final String sub in subtitlePaths)
          if (ctx.equals(ctx.dirname(sub), dir) &&
              splitAudiobookSubtitleName(ctx.basename(sub)).stem ==
                  stem.toLowerCase().trim())
            sub,
      ],
      subtitleLangCode: subtitleLangCode,
      title: titleByBookPath[book]!,
    );
  }
  return out;
}

class _Claim {
  const _Claim({required this.units, required this.rule});
  final List<AudiobookUnit> units;
  final BookAudiobookPairRule rule;
}

BookAudiobookPairing _pairingOf({
  required String book,
  required List<AudiobookUnit> units,
  required BookAudiobookPairRule rule,
  required List<String> bookStemSubtitles,
  required String subtitleLangCode,
  required String title,
}) {
  final List<String> audio = _sortedAudio(<String>[
    for (final AudiobookUnit unit in units) ...unit.audioPaths,
  ]);
  final List<String> pool = <String>{
    for (final AudiobookUnit unit in units) ...unit.subtitlePaths,
    ...bookStemSubtitles,
  }.toList()..sort();
  final AudiobookSubtitlePick? pick = pool.isEmpty
      ? null
      : pickAudiobookSubtitle(
          audioNames: audio,
          subtitleNames: pool,
          title: title,
          langCode: subtitleLangCode,
        );
  return BookAudiobookPairing(
    bookPath: book,
    subtitlePath: pick == null ? null : pool[pick.index],
    audioPaths: audio,
    rule: rule,
  );
}

/// 播放顺序：先按所在目录逐段自然序（父目录里散放的在前，`CD2` < `CD10`），同目录
/// 再按文件自然序。只按文件名排会把 `CD2/01.mp3` 排到 `CD1/02.mp3` 前面。
List<String> _sortedAudio(List<String> audio) {
  List<String> dirSegments(String path) {
    final List<String> segments = path.replaceAll(r'\', '/').split('/');
    return segments.sublist(0, segments.length - 1);
  }

  int compareDirs(List<String> a, List<String> b) {
    final int n = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final int c = compareAudioFilePath(a[i], b[i]);
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  return <String>[...audio]..sort((String a, String b) {
    final int byDir = compareDirs(dirSegments(a), dirSegments(b));
    return byDir != 0 ? byDir : compareAudioFilePath(a, b);
  });
}

/// R3：按目录 + 系列键整组算卷号配对。返回 书 → 认领；组内不能一一对应时整组书
/// 记进 [ambiguous]。
Map<String, _Claim> _volumeClaims({
  required List<String> books,
  required _UnitIndex index,
  required Set<AudiobookUnit> excludedUnits,
  required p.Context ctx,
  required Set<String> ambiguous,
}) {
  // 目录 → 系列键 → 这一组的书（带卷号的）。
  final Map<String, Map<String, List<({String book, num volume})>>> groups =
      <String, Map<String, List<({String book, num volume})>>>{};
  final Map<String, String> seriesTitleOf = <String, String>{};
  for (final String book in books) {
    final BookSeriesKey? key = parseBookSeriesKey(
      ctx.basenameWithoutExtension(book),
    );
    final num? volume = key?.volume;
    if (key == null || volume == null) continue;
    ((groups[ctx.dirname(book)] ??=
                <String, List<({String book, num volume})>>{})[key.key] ??=
            <({String book, num volume})>[])
        .add((book: book, volume: volume));
    seriesTitleOf[key.key] = key.seriesTitle;
  }

  final Map<String, _Claim> out = <String, _Claim>{};
  groups.forEach((
    String dir,
    Map<String, List<({String book, num volume})>> bySeries,
  ) {
    bySeries.forEach((
      String seriesKey,
      List<({String book, num volume})> group,
    ) {
      final String seriesTitle = seriesTitleOf[seriesKey]!;
      // 本组认得出卷号的单元：子目录单元可以只写卷号（`Vol.1/`、`01/`）；散放文件
      // 必须带同一系列名（`01.mp3` 多半是一本书的第 1 轨，不是第 1 卷）。
      final Map<num, List<AudiobookUnit>> unitsByVolume =
          <num, List<AudiobookUnit>>{};
      for (final AudiobookUnit unit in index.scopeUnitsOf(dir)) {
        if (excludedUnits.contains(unit)) continue;
        final num? volume = _unitVolume(
          unit,
          seriesKey: seriesKey,
          seriesTitle: seriesTitle,
          isFolder: index.isFolderUnit(unit),
        );
        if (volume == null) continue;
        (unitsByVolume[volume] ??= <AudiobookUnit>[]).add(unit);
      }
      if (unitsByVolume.isEmpty) return;
      final Map<num, List<String>> booksByVolume = <num, List<String>>{};
      for (final ({String book, num volume}) entry in group) {
        (booksByVolume[entry.volume] ??= <String>[]).add(entry.book);
      }
      bool bijective = true;
      unitsByVolume.forEach((num volume, List<AudiobookUnit> units) {
        if (units.length != 1 || booksByVolume[volume]?.length != 1) {
          bijective = false;
        }
      });
      booksByVolume.forEach((num volume, List<String> sameVolume) {
        if (sameVolume.length > 1 && unitsByVolume.containsKey(volume)) {
          bijective = false;
        }
      });
      if (!bijective) {
        ambiguous.addAll(<String>[
          for (final ({String book, num volume}) entry in group) entry.book,
        ]);
        return;
      }
      for (final ({String book, num volume}) entry in group) {
        final List<AudiobookUnit>? units = unitsByVolume[entry.volume];
        if (units == null) continue;
        out[entry.book] = _Claim(
          units: units,
          rule: BookAudiobookPairRule.volume,
        );
      }
    });
  });
  return out;
}

num? _unitVolume(
  AudiobookUnit unit, {
  required String seriesKey,
  required String seriesTitle,
  required bool isFolder,
}) {
  final BookSeriesKey? key = parseBookSeriesKey(unit.title);
  if (key != null && key.key == seriesKey && key.volume != null) {
    return key.volume;
  }
  if (!isFolder) return null;
  return parseBookVolumeFolderName(
    unit.title,
    seriesFolderName: seriesTitle,
  )?.volume;
}

/// 把音频 / 字幕按目录归成单元的索引。
class _UnitIndex {
  _UnitIndex._(this._ctx);

  final p.Context _ctx;

  /// 单元身份 → 单元（按身份排序）。
  final Map<String, AudiobookUnit> _units = <String, AudiobookUnit>{};
  final Set<AudiobookUnit> _folderUnits = Set<AudiobookUnit>.identity();

  /// 目录 → 直接位于其中的字幕。
  final Map<String, List<String>> _subtitlesByDir = <String, List<String>>{};

  static _UnitIndex build({
    required List<String> audioPaths,
    required List<String> subtitlePaths,
    required p.Context ctx,
  }) {
    final _UnitIndex index = _UnitIndex._(ctx);
    for (final String sub in subtitlePaths) {
      (index._subtitlesByDir[ctx.dirname(sub)] ??= <String>[]).add(sub);
    }

    // 音频的「单元目录」：分碟目录并进上一层。
    String unitDirOf(String audio) {
      final String dir = ctx.dirname(audio);
      return isAudiobookDiscFolderName(ctx.basename(dir))
          ? ctx.dirname(dir)
          : dir;
    }

    // 某层目录 L 上的音频：直接在 L 里的（散放） + L 下分碟目录里的。
    final Map<String, List<String>> looseByLevel = <String, List<String>>{};
    final Map<String, List<String>> discByLevel = <String, List<String>>{};
    for (final String audio in audioPaths) {
      final String dir = ctx.dirname(audio);
      final String level = unitDirOf(audio);
      if (ctx.equals(dir, level)) {
        (looseByLevel[level] ??= <String>[]).add(audio);
      } else {
        (discByLevel[level] ??= <String>[]).add(audio);
      }
    }
    final Set<String> levels = <String>{
      ...looseByLevel.keys,
      ...discByLevel.keys,
    };

    // 子目录单元：每个有音频的层 L（不是来源根本身也无所谓——父目录里没书就没人认领）
    // 作为它父目录的一个子目录单元。
    for (final String level in levels) {
      final List<String> audio = <String>[
        ...?looseByLevel[level],
        ...?discByLevel[level],
      ];
      final String parent = ctx.dirname(level);
      if (ctx.equals(parent, level)) continue; // 文件系统根
      final String key = 'dir:$level';
      index._units[key] = AudiobookUnit(
        path: level,
        scopeDir: parent,
        title: ctx.basename(level),
        audioPaths: _sortedAudio(audio),
        subtitlePaths: <String>[
          ...?index._subtitlesByDir[level],
          for (final String disc in _discDirsUnder(level, audio, ctx))
            ...?index._subtitlesByDir[disc],
        ]..sort(),
      );
      index._folderUnits.add(index._units[key]!);
    }

    // 层单元：L 里散放的每个文件各一个单元；L 下分碟目录合成一个单元。
    for (final String level in levels) {
      for (final String audio in looseByLevel[level] ?? const <String>[]) {
        final String stem = ctx.basenameWithoutExtension(audio).toLowerCase();
        index._units['file:$audio'] = AudiobookUnit(
          path: audio,
          scopeDir: level,
          title: ctx.basenameWithoutExtension(audio),
          audioPaths: <String>[audio],
          subtitlePaths: <String>[
            for (final String sub
                in index._subtitlesByDir[level] ?? const <String>[])
              if (splitAudiobookSubtitleName(ctx.basename(sub)).stem == stem ||
                  _baseLower(ctx, sub) == stem)
                sub,
          ]..sort(),
        );
      }
      final List<String>? disc = discByLevel[level];
      if (disc != null) {
        index._units['disc:$level'] = AudiobookUnit(
          path: level,
          scopeDir: level,
          title: ctx.basename(level),
          audioPaths: _sortedAudio(disc),
          subtitlePaths: <String>[
            for (final String dir in _discDirsUnder(level, disc, ctx))
              ...?index._subtitlesByDir[dir],
          ]..sort(),
        );
      }
    }
    return index;
  }

  static String _baseLower(p.Context ctx, String path) =>
      ctx.basenameWithoutExtension(path).toLowerCase().trim();

  static List<String> _discDirsUnder(
    String level,
    List<String> audio,
    p.Context ctx,
  ) => <String>{
    for (final String a in audio)
      if (!ctx.equals(ctx.dirname(a), level)) ctx.dirname(a),
  }.toList()..sort();

  List<AudiobookUnit> get allUnits {
    final List<String> keys = _units.keys.toList()..sort();
    return <AudiobookUnit>[for (final String key in keys) _units[key]!];
  }

  bool isFolderUnit(AudiobookUnit unit) => _folderUnits.contains(unit);

  /// [dir] 的直接子目录单元。
  List<AudiobookUnit> childUnitsOf(String dir) => <AudiobookUnit>[
    for (final AudiobookUnit unit in allUnits)
      if (isFolderUnit(unit) && _ctx.equals(unit.scopeDir, dir)) unit,
  ];

  /// [dir] 这一层的单元（散放文件 + 分碟合集）。
  List<AudiobookUnit> levelUnitsOf(String dir) => <AudiobookUnit>[
    for (final AudiobookUnit unit in allUnits)
      if (!isFolderUnit(unit) && _ctx.equals(unit.scopeDir, dir)) unit,
  ];

  /// [dir] 里的书能认领的全部单元。
  List<AudiobookUnit> scopeUnitsOf(String dir) => <AudiobookUnit>[
    for (final AudiobookUnit unit in allUnits)
      if (_ctx.equals(unit.scopeDir, dir)) unit,
  ];

  /// [dir] 里与书主干 [stem] 同主干（可带语言标记）的字幕。
  List<String> subtitlesWithStemIn(String dir, String stem) {
    final String want = stem.toLowerCase().trim();
    return <String>[
      for (final String sub in _subtitlesByDir[dir] ?? const <String>[])
        if (splitAudiobookSubtitleName(_ctx.basename(sub)).stem == want ||
            _baseLower(_ctx, sub) == want)
          sub,
    ];
  }
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
