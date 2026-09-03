import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// v1 六列（无 `options`）。旧文件与旧 Hibiki 版本仍在用，读写两侧都必须继续认它。
const String _profileHeaderV1 =
    'exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel';

/// v2 七列，尾列 `options` 是分号分隔的开关，与 native 侧
/// `native/galgame_hook/include/luna_hook_config.h` 的 schema 一致：
/// `pc-hooks` / `block=<hook-code>` / `block-name=<Luna 名>` / `prefer=<hook-code>` /
/// `defer-ms=<毫秒>`。Dart 侧只做逐字保真搬运（解析/生效在 native），不解释语义——
/// 解释一遍等于开第二个真相源。
const String _profileHeaderV2 = '$_profileHeaderV1\toptions';

/// 行首前缀判表头：v1 六列头与 v2 七列头都命中，与 native 的
/// `line.rfind("exe_sha256\t", 0) == 0` 同一判据。数据行首列只可能是 64 位 hex 或空，
/// 不会误伤。
const String _profileHeaderPrefix = 'exe_sha256\t';

/// 最少列数。多出来的列（未来 v3）按 native 的做法忽略——v1/v2/v3 互为前缀子集，
/// 这才是「不崩」的真正来源。
const int _profileMinColumns = 6;

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// BUG-1909：把用户**粘来的一串特殊码**归一成可入库的形式。
///
/// 用户原话：「特殊码确实是可以用在 fushi 上的，不过要稍微转换一下，因为 fushi 只接受
/// tsv 合适的，一般特殊码只是一串字符」。这里做的正是那个「转换」的第一半——把散字符
/// 洗干净；第二半（补 exe SHA-256 / codepage / label 拼成七列 TSV 行）由调用方完成。
///
/// 只做三件**不改变语义**的事：
/// 1. 去掉首尾空白与包裹的引号 —— 从网页/聊天里复制常常带着；
/// 2. 去掉**所有**内部空白（含换行）—— 特殊码里没有合法空白，换行只会来自复制时的软折行；
/// 3. 全角 ASCII → 半角 —— 特殊码按定义是纯 ASCII，中日文 IME 下粘出来的 `／Ｈ...`
///    native 一个字也认不出，而这是纯粹的输入法噪声，不是用户意图。
///
/// **刻意不碰码本身的结构**（不补/不删开头的 `/`、不改大小写、不重排 `@` 后的地址）：
/// Hibiki 从头到尾把 hook code 当**不透明字符串**搬运，真正的词法解析在 LunaHost DLL
/// 里（本仓 `third_party/lunahook/` 只有二进制，没有源码可复用）。在这里替 native
/// 猜格式，就是开第二个真相源。
String normalizeGalHookCode(String raw) {
  String value = raw.trim();
  // 成对的包裹引号（英文/中文/日文引号都见过）。
  const List<List<String>> quotePairs = <List<String>>[
    <String>['"', '"'],
    <String>["'", "'"],
    <String>['`', '`'],
    <String>['“', '”'],
    <String>['「', '」'],
    <String>['『', '』'],
  ];
  bool stripped = true;
  while (stripped && value.length >= 2) {
    stripped = false;
    for (final List<String> pair in quotePairs) {
      if (value.startsWith(pair[0]) && value.endsWith(pair[1])) {
        value = value.substring(1, value.length - 1).trim();
        stripped = true;
        break;
      }
    }
  }
  final StringBuffer buf = StringBuffer();
  for (final int unit in value.runes) {
    // 全角空格单独处理（它不在 FF01..FF5E 区间里）。
    if (unit == 0x3000) continue;
    if (unit <= 0x20 || unit == 0x7f) continue; // 半角空白/控制字符
    // 全角 ASCII（！..～）→ 半角，偏移恒为 0xFEE0。
    buf.writeCharCode(
      (unit >= 0xff01 && unit <= 0xff5e) ? unit - 0xfee0 : unit,
    );
  }
  return buf.toString();
}

class LunaHookCodeProfile {
  const LunaHookCodeProfile({
    required this.executableSha256,
    required this.moduleName,
    required this.moduleSha256,
    required this.codepage,
    required this.hookCode,
    required this.label,
    this.options = '',
  });

  final String executableSha256;
  final String moduleName;
  final String moduleSha256;
  final int codepage;
  final String hookCode;
  final String label;

  /// v2 尾列，原样保存的分号分隔开关串。v1 行 / 未使用时为空串。
  final String options;

  String get identityKey =>
      '$executableSha256|${moduleName.toLowerCase()}|$moduleSha256|$hookCode'
      '|$options';

  void validate() {
    if (executableSha256.isEmpty && moduleSha256.isEmpty) {
      throw const FormatException(
          'A profile needs an executable or module hash.');
    }
    if (executableSha256.isNotEmpty &&
        !_sha256Pattern.hasMatch(executableSha256)) {
      throw const FormatException('Invalid executable SHA-256.');
    }
    if (moduleSha256.isNotEmpty &&
        (!_sha256Pattern.hasMatch(moduleSha256) || moduleName.isEmpty)) {
      throw const FormatException('A module hash needs a valid hash and name.');
    }
    // v2 允许「只带 options、不带 hook code」的行（block=/prefer=/defer-ms= 这类
    // 只约束自动探测的 profile，native 侧 `fields[4]` 为空是合法的）；但一行既没有
    // hook code 又没有 options 就什么都没说，仍然是错的。
    if (codepage <= 0 || (hookCode.trim().isEmpty && options.trim().isEmpty)) {
      throw const FormatException('Invalid codepage or empty Hook Code.');
    }
    if (<String>[moduleName, hookCode, label, options].any((value) =>
        value.contains('\t') || value.contains('\n') || value.contains('\r'))) {
      throw const FormatException(
          'Profile fields cannot contain tabs or lines.');
    }
  }

  String toTsvRow({bool includeOptions = true}) => <Object>[
        executableSha256,
        moduleName,
        moduleSha256,
        codepage,
        hookCode,
        label,
        if (includeOptions) options,
      ].join('\t');
}

List<LunaHookCodeProfile> parseLunaHookCodeProfiles(String input) {
  final List<LunaHookCodeProfile> result = <LunaHookCodeProfile>[];
  for (final String rawLine in const LineSplitter().convert(input)) {
    final String line = rawLine.trimRight();
    if (line.isEmpty ||
        line.startsWith('#') ||
        line.startsWith(_profileHeaderPrefix)) {
      continue;
    }
    final List<String> fields = line.split('\t');
    if (fields.length < _profileMinColumns) {
      throw const FormatException(
          'Hook Code profile rows need at least six columns.');
    }
    final LunaHookCodeProfile profile = LunaHookCodeProfile(
      executableSha256: fields[0].toLowerCase(),
      moduleName: fields[1],
      moduleSha256: fields[2].toLowerCase(),
      codepage: int.tryParse(fields[3]) ?? 0,
      hookCode: fields[4],
      label: fields[5],
      options: fields.length > 6 ? fields[6] : '',
    );
    profile.validate();
    result.add(profile);
  }
  return result;
}

String encodeLunaHookCodeProfiles(Iterable<LunaHookCodeProfile> profiles) {
  final List<LunaHookCodeProfile> sorted = profiles.toList()
    ..sort((a, b) => a.identityKey.compareTo(b.identityKey));
  // 没有任何一行用到 options 就照旧写 v1：绝大多数用户表按字节不变，旧版本 Hibiki
  // （只认六列）读自己的表不会炸。真有 options 要存时才升 v2——native 的解析器本来
  // 就同时吃 v1/v2。
  final bool needsOptions =
      sorted.any((LunaHookCodeProfile profile) => profile.options.isNotEmpty);
  return <String>[
    '# Hibiki Luna hook-code profiles ${needsOptions ? 'v2' : 'v1'}. '
        'UTF-8, tab separated.',
    needsOptions ? _profileHeaderV2 : _profileHeaderV1,
    ...sorted.map((profile) => profile.toTsvRow(includeOptions: needsOptions)),
    '',
  ].join('\n');
}

Future<String> sha256File(File file) async =>
    sha256.convert(await file.readAsBytes()).toString();

class LunaHookCodeProfileStore {
  LunaHookCodeProfileStore(this.file);

  final File file;

  static Future<LunaHookCodeProfileStore> openDefault() async {
    final Directory root = await AppPaths.supportRootDirectory();
    final File file =
        File(p.join(root.path, 'galgame', 'luna_hook_profiles.tsv'));
    final LunaHookCodeProfileStore store = LunaHookCodeProfileStore(file);
    await store.ensureExists();
    return store;
  }

  Future<void> ensureExists() async {
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      await file.writeAsString(encodeLunaHookCodeProfiles(const []),
          encoding: utf8, flush: true);
    }
  }

  Future<List<LunaHookCodeProfile>> load() async {
    await ensureExists();
    return parseLunaHookCodeProfiles(await file.readAsString(encoding: utf8));
  }

  Future<void> replaceFrom(File imported) async {
    final List<LunaHookCodeProfile> profiles =
        parseLunaHookCodeProfiles(await imported.readAsString(encoding: utf8));
    await save(profiles);
  }

  Future<void> exportTo(File destination) async {
    await destination.writeAsString(
      encodeLunaHookCodeProfiles(await load()),
      encoding: utf8,
      flush: true,
    );
  }

  Future<void> upsert(LunaHookCodeProfile profile) async {
    profile.validate();
    final List<LunaHookCodeProfile> profiles = await load();
    profiles.removeWhere((item) => item.identityKey == profile.identityKey);
    profiles.add(profile);
    await save(profiles);
  }

  Future<void> save(Iterable<LunaHookCodeProfile> profiles) async {
    for (final LunaHookCodeProfile profile in profiles) {
      profile.validate();
    }
    await ensureExists();
    await file.writeAsString(
      encodeLunaHookCodeProfiles(profiles),
      encoding: utf8,
      flush: true,
    );
  }
}
