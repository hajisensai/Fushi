// 词典「已登记但文件不在 / 读不到」的判定与状态（BUG-5489）。
//
// 词典元数据住在库里（`dictionary_metadata`），文件住在 `<书库根>/dictionaryResources/
// <名>/`。两边一旦脱节（书库根被清、换了位置、外部存储被拔），装载链路
// （`AppModel._scheduleDictPathsAsync` → `bucketDictPaths`）只是把不存在 / 读不到的目录
// 当成「不进引擎」静默跳过，C++ 的 `add_dict` 缺文件也是直接 return——词典列表照旧、
// 开关照旧，查词只剩「未找到」，用户无从知道是数据没了。
//
// 本文件只做判定与状态发布，**从不删任何东西**：读不到（存储未挂载、没权限）与真的
// 不在分成两种状态，前者只提示、等它回来；后者给用户「重新导入 / 删除」的出路，删除
// 也只由用户点。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:path/path.dart' as path;

/// 一本已登记词典的文件问题。
enum DictionaryFileIssue {
  /// 文件不在：资源根可读，但这本的目录没了，或目录里缺了装载必需的文件。
  missing,

  /// 暂时读不到：资源根本身不可读（存储未挂载 / 没权限），或目录在但读文件出错。
  /// 只提示，不当成删除。
  unreadable,
}

/// 装载必需的文件（与 `native/fushidicts` 的 `add_dict` 同口径）：`index.json`、记录
/// 文件（`blobs.bin` / `blobs3.bin` 之一）、索引（`key.index` / 旧式 `hash.table` 之一）。
/// 缺任何一组，`add_dict` 都会静默 return。
const List<List<String>> kDictionaryRequiredFileGroups = <List<String>>[
  <String>['index.json'],
  <String>['blobs.bin', 'blobs3.bin'],
  <String>['key.index', 'hash.table'],
];

/// [dir] 里装载必需的文件是否齐全（只 stat，不读内容——dataless 文件 stat 不会触发回填）。
Future<bool> dictionaryFilesComplete(String dir) async {
  for (final List<String> group in kDictionaryRequiredFileGroups) {
    bool any = false;
    for (final String name in group) {
      if (await File(path.join(dir, name)).exists()) {
        any = true;
        break;
      }
    }
    if (!any) return false;
  }
  return true;
}

/// [dictionaryFilesComplete] 的同步版，只给「已知有问题的那几本」复查用（同步重建路径）。
bool dictionaryFilesCompleteSync(String dir) {
  for (final List<String> group in kDictionaryRequiredFileGroups) {
    if (!group.any((String name) => File(path.join(dir, name)).existsSync())) {
      return false;
    }
  }
  return true;
}

/// 资源根此刻能不能列目录。列不出来（不存在、外部存储未挂载、没权限）时，各本目录
/// 「不存在」的结论不可信——只能说读不到，不能说没了。
Future<bool> dictionaryResourceRootReadable(Directory root) async {
  try {
    if (!await root.exists()) return false;
    await root.list(followLinks: false).isEmpty;
    return true;
  } on FileSystemException {
    return false;
  }
}

/// 本机登记的词典按磁盘文件分出的两组（[localDictionaryFileStates]）。
typedef LocalDictionaryFileStates = ({
  /// 装载必需的文件齐全：本机真有这本（可以打包推给别人，别人的同名副本不必再拉）。
  Set<String> complete,

  /// 资源根可读、但这本的文件不在 / 不全（与 [DictionaryFileIssue.missing] 同口径）：本机
  /// 只剩元数据，别处有同名副本时应当拉回来恢复，绝不能拿它打包推出去（推出去的是空包）。
  Set<String> restorable,
});

/// 「本机到底有没有这本词典」的唯一判据（同步的词典阶段、按 host 的单本传输共用）：只看
/// 元数据会把文件丢了的词典当成「已装」——既拉不回来、还会把空目录打成包推给别人
/// （反馈 ujt4V8GdT8）。资源根读不到时两组都是空的：读不到不等于没了，既不推也不拉。
Future<LocalDictionaryFileStates> localDictionaryFileStates(
  Directory root,
  Iterable<String> names,
) async {
  final Set<String> complete = <String>{};
  final Set<String> restorable = <String>{};
  if (!await dictionaryResourceRootReadable(root)) {
    return (complete: complete, restorable: restorable);
  }
  for (final String name in names) {
    if (await dictionaryFilesComplete(path.join(root.path, name))) {
      complete.add(name);
    } else {
      restorable.add(name);
    }
  }
  return (complete: complete, restorable: restorable);
}

/// 单本词典的判定（纯函数）。[probeError] 是物化探测（`DictResourceAvailability`）这一轮
/// 对这本目录报的错；[filesComplete] 只在目录存在且探测没报错时有意义。
DictionaryFileIssue? classifyDictionaryFiles({
  required bool rootReadable,
  required bool dirExists,
  required bool filesComplete,
  String? probeError,
}) {
  if (!rootReadable) {
    return dirExists && probeError == null && filesComplete
        ? null
        : DictionaryFileIssue.unreadable;
  }
  if (!dirExists) return DictionaryFileIssue.missing;
  if (probeError != null) {
    // 探测与本轮 exists 之间目录被删：同样是不在。其余（打不开 / 读不出）是读不到。
    return probeError.startsWith('directory missing')
        ? DictionaryFileIssue.missing
        : DictionaryFileIssue.unreadable;
  }
  return filesComplete ? null : DictionaryFileIssue.missing;
}

/// 一次判定的整体结果：按真名（`Dictionary.name`）记每本的问题，外加查词视角的计数
/// （只算查词时会用到的词条词典：非隐藏的 term 词典）。
@immutable
class DictionaryFileHealth {
  const DictionaryFileHealth({
    this.issues = const <String, DictionaryFileIssue>{},
    this.lookupTermTotal = 0,
    this.lookupTermMissing = 0,
    this.lookupTermUnreadable = 0,
  });

  static const DictionaryFileHealth healthy = DictionaryFileHealth();

  /// 真名 → 问题；没问题的词典不在表里。
  final Map<String, DictionaryFileIssue> issues;

  /// 查词会用到的词条词典总数（非隐藏的 term 词典）。
  final int lookupTermTotal;

  /// 其中文件不在的本数。
  final int lookupTermMissing;

  /// 其中暂时读不到的本数。
  final int lookupTermUnreadable;

  bool get isHealthy => issues.isEmpty;

  DictionaryFileIssue? issueOf(String name) => issues[name];

  int get missingCount => issues.values
      .where((DictionaryFileIssue i) => i == DictionaryFileIssue.missing)
      .length;

  int get unreadableCount => issues.values
      .where((DictionaryFileIssue i) => i == DictionaryFileIssue.unreadable)
      .length;

  /// 查词视角：所有会用到的词条词典都有问题（一本都查不了）。
  bool get affectsAllLookups =>
      lookupTermTotal > 0 &&
      lookupTermMissing + lookupTermUnreadable >= lookupTermTotal;

  /// 诊断文本（数据位置取证环，按文本比较是否变化，故按名字排序、逐字稳定）。
  String describe({required String resourceRoot}) {
    List<String> namesOf(DictionaryFileIssue issue) => <String>[
      for (final MapEntry<String, DictionaryFileIssue> e in issues.entries)
        if (e.value == issue) e.key,
    ]..sort();
    final List<String> missing = namesOf(DictionaryFileIssue.missing);
    final List<String> unreadable = namesOf(DictionaryFileIssue.unreadable);
    return <String>[
      'root=$resourceRoot',
      'lookupTerm=$lookupTermTotal missing=$lookupTermMissing '
          'unreadable=$lookupTermUnreadable',
      if (missing.isNotEmpty)
        'missing(${missing.length}): ${missing.join(', ')}',
      if (unreadable.isNotEmpty)
        'unreadable(${unreadable.length}): ${unreadable.join(', ')}',
      if (issues.isEmpty) 'all registered dictionaries have their files',
    ].join('\n');
  }

  @override
  bool operator ==(Object other) =>
      other is DictionaryFileHealth &&
      other.lookupTermTotal == lookupTermTotal &&
      other.lookupTermMissing == lookupTermMissing &&
      other.lookupTermUnreadable == lookupTermUnreadable &&
      mapEquals(other.issues, issues);

  @override
  int get hashCode => Object.hash(
    lookupTermTotal,
    lookupTermMissing,
    lookupTermUnreadable,
    Object.hashAllUnordered(
      issues.entries.map(
        (MapEntry<String, DictionaryFileIssue> e) =>
            Object.hash(e.key, e.value),
      ),
    ),
  );
}

/// 进程内最新一次判定（`AppModel` 在两条词典装载路径上发布）。查词浮层、首页词典页、
/// WebView 弹窗注入、词典管理页都读它——它们不一定挂在同一个 Provider 作用域里，所以是
/// 一个进程级的可监听值（Android `:popup` 进程自己的 AppModel 自己发布自己的）。
class DictionaryFileHealthMonitor extends ValueNotifier<DictionaryFileHealth> {
  DictionaryFileHealthMonitor._() : super(DictionaryFileHealth.healthy);

  static final DictionaryFileHealthMonitor instance =
      DictionaryFileHealthMonitor._();
}

/// 查词结果为空 / 不全时要给用户看的那句话；没有影响查词的问题时为 null（隐藏词典、
/// 频率 / 音调词典的文件问题只在词典管理里标出，不打扰查词）。
String? dictionaryLookupFileNotice(DictionaryFileHealth health) {
  final int affected = health.lookupTermMissing + health.lookupTermUnreadable;
  if (affected == 0) return null;
  if (health.affectsAllLookups) {
    return health.lookupTermMissing > 0
        ? t.dictionary_files_lookup_all_missing
        : t.dictionary_files_lookup_all_unreadable;
  }
  return health.lookupTermMissing > 0
      ? t.dictionary_files_lookup_some_missing(n: health.lookupTermMissing)
      : t.dictionary_files_lookup_some_unreadable(
          n: health.lookupTermUnreadable,
        );
}
