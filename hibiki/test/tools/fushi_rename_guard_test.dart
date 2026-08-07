import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// ---------------------------------------------------------------------------
// Fushi 改名收尾守卫：旧代号在**代码位**零残留（P6 系列批次的反向锁）。
//
// 扫描面：`lib/` + 六个内部 fushi_* 包的 `lib/`（vendored 第三方 fork 不扫——
// 不是我们的命名域）。逐文件用 [maskCommentsAndScriptLines] 把 Dart 注释 **和**
// 三引号串内嵌 JS/CSS 语料的注释都换成等长空白后再匹配：注释里的历史叙述
// （「旧名 hoshiReader…」）不算残留，字符串字面量与标识符才算。
//
// 白名单按「文件 + 模式」收口，一条一个理由；且带过期豁免检测——某条白名单
// 命中数归零（残留已被清掉/文件被删）时测试转红，逼着把这条豁免一起删掉，
// 防止白名单退化成永久盲区（同 md3_design_system_static_test 的 allowlist 纪律）。
// ---------------------------------------------------------------------------

/// 一条被禁模式：老代号的代码位形态。
class _ForbiddenPattern {
  const _ForbiddenPattern({
    required this.name,
    required this.regex,
    this.allowed = const <String, String>{},
  });

  /// 报错用短名。
  final String name;

  /// 在剥掉注释后的源码上匹配。
  final RegExp regex;

  /// 豁免表：文件路径后缀（正斜杠归一）→ 理由。命中豁免文件的匹配不算违规，
  /// 但每条豁免必须仍有 ≥1 次命中（过期豁免检测）。
  final Map<String, String> allowed;
}

const String _sasayakiFrozenNote = '（P6-4b 冻结契约点，进度台账有案）';

final List<_ForbiddenPattern> _forbidden = <_ForbiddenPattern>[
  _ForbiddenPattern(
    // P6-1：JS 桥全局已是 window.fushiReader。
    name: 'hoshiReader',
    regex: RegExp('hoshiReader', caseSensitive: false),
  ),
  _ForbiddenPattern(
    // W3：阅读器虚拟拦截域已是 fushi.local（纯运行时符号，每次页面加载现拼，
    // 无持久化形态；`hoshi://book/` mediaIdentifier 是另一符号、DB 持久化契约，
    // 刻意不在此模式内）。
    name: 'hoshi.local',
    regex: RegExp(r'hoshi\.local', caseSensitive: false),
  ),
  _ForbiddenPattern(
    // P6-3：setTtu*/getTtu* 访问器已换 setReader*/getReader*。
    // （`ttu_*` 持久化键值本身冻结在 reader_settings.dart，不在此模式内。）
    name: 'setTtu/getTtu',
    regex: RegExp(r'\b(?:set|get)Ttu'),
  ),
  _ForbiddenPattern(
    // P6-4b：Sasayaki* → SubtitleRematch*/sentenceAudio*。
    name: 'sasayaki',
    regex: RegExp('sasayaki', caseSensitive: false),
    allowed: <String, String>{
      'lib/src/models/theme_notifier.dart':
          "自定义主题的 'sasayakiColor' JSON 键（custom_themes 旧数据/分享码）与 "
              "'custom_theme_sasayaki_color' 偏好键（Drift preferences 表）是持久化"
              '契约$_sasayakiFrozenNote。',
      'lib/src/pages/implementations/anki_settings_page.dart':
          "'{sasayaki-audio}' 是 {sentence-audio} 的 handlebars 旧别名（用户卡模板"
              '契约），其展示标签读冻结 i18n key handlebar_sasayaki_audio'
              '$_sasayakiFrozenNote。',
      'lib/i18n/strings.g.dart':
          'Slang 生成文件：冻结 i18n key handlebar_sasayaki_audio 的 getter 与'
              '各语言展示值（i18n 值面清扫是独立事项）。生成源是 *.i18n.json，'
              '不手改。',
      'packages/fushi_anki/lib/src/anki_models.dart':
          "'{sasayaki-audio}' handlebars 旧别名的解析/枚举/兼容判定（用户卡模板"
              '契约）$_sasayakiFrozenNote。',
      'packages/fushi_audio/lib/src/matching/subtitle_rematch_codec.dart':
          "'sasayaki://' scheme 字面量落 Drift DB 的 AudioCue.text_fragment_id 列，"
              '持久化契约$_sasayakiFrozenNote。',
    },
  ),
  _ForbiddenPattern(
    // P6-4a：torrent DTO 前缀 Ht* → Ft*。
    name: 'Ht*-DTO 前缀',
    regex: RegExp(r'\bHt[A-Z]'),
  ),
  _ForbiddenPattern(
    // P2-1：applicationId/MethodChannel 已切 app.fushi.reader。
    name: 'app.hibiki.reader',
    regex: RegExp(r'app\.hibiki\.reader'),
    allowed: <String, String>{
      'lib/src/migration/migration_target_channel.dart':
          'kHibikiPackageName 迁移常量：Fushi 侧探测/拉起/卸载旧包（老包身份是'
              '迁移链的事实，不随改名走）。消费方一律引用该常量，不再落新字面量。',
    },
  ),
  _ForbiddenPattern(
    // 云同步改名：同步根已是 fushi-data。
    name: 'hibiki-data',
    regex: RegExp('hibiki-data'),
    allowed: <String, String>{
      'lib/src/sync/sync_utils.dart':
          'kLegacySyncRootFolderName：五个远端后端做 hibiki-data → fushi-data '
              '一次性改名迁移时识别旧根用，旧字面量必须保留。消费方引用常量。',
    },
  ),
  _ForbiddenPattern(
    // Phase 3：Windows 单实例互斥体已是 FushiSingleInstanceMutex。
    name: 'HibikiSingleInstanceMutex',
    regex: RegExp('HibikiSingleInstanceMutex'),
  ),
  _ForbiddenPattern(
    // P6-5：pub 包体系已是 fushi / fushi_*（也覆盖 package:hibiki_core 等旧内部包）。
    name: 'package:hibiki',
    regex: RegExp('package:hibiki'),
  ),
  _ForbiddenPattern(
    // W5：JS 运行时 camel 符号族已是 fushi*/Fushi*（window.fushiSelection、
    // fushiCaret、__fushi* 内部符号、[FushiVN]/[FushiInit] log tag、陈旧
    // HoshiDicts/HoshiLookupResult 引擎类引用等）。解析冻结持久化格式
    // `hoshi://book/<key>` 的 Dart 私有名命名跟随格式本名，见白名单。
    name: 'hoshi*-camel 运行时符号族',
    regex: RegExp('[Hh]oshi[A-Z]'),
    allowed: <String, String>{
      'lib/src/sync/app_model_library_host_service.dart':
          '_hoshiBookKeyPattern：解析冻结 mediaIdentifier 格式 hoshi://book/'
              '<key>（DB 持久化契约，行改写归 W2），命名跟随格式本名。',
      'lib/src/utils/misc/shelf_ordering.dart':
          '_parseHoshiBookKey：同上，解析冻结 hoshi://book/ 键格式。',
    },
  ),
  _ForbiddenPattern(
    // W5：注入 CSS 变量/类/data-属性/Highlight registry 名已是
    // --fushi-*/.fushi-*/data-fushi-*（每次注入现拼，无持久化形态）。
    name: 'hoshi- CSS/DOM 词根',
    regex: RegExp('hoshi-'),
  ),
  _ForbiddenPattern(
    // W5：snake 运行时名（JS handler/ValueKey/DOM id/词典媒体缓存文件前缀）
    // 已是 fushi_*。白名单法逐段列举——冻结的 hoshi_books / hoshi_anki_settings /
    // google_drive_hoshi_compat 等磁盘目录/偏好键刻意不在此模式内。
    name: 'hoshi_* snake 运行时名',
    regex: RegExp(r'hoshi_(?:content_ready|lyrics_ready|progress|play_bar'
        r'|webview|lyrics_mode_toggle|shell_|dict_|audio_css)'),
  ),
  _ForbiddenPattern(
    // W5：Apple 端阅读器资源 scheme 已是 fushi-reader（纯运行时 URL scheme，
    // 注册与拦截两侧同引 ReaderCustomFontCss.kReaderResourceScheme 常量）。
    name: 'hibiki-reader-scheme',
    regex: RegExp('hibiki-reader'),
  ),
  _ForbiddenPattern(
    // 类名族清算：Hibiki* → Fushi*（HibikiDatabase/HibikiToast/_HibikiCardState
    // 等词首形态，含 _$Hibiki* 生成类）。词中内嵌形态不属类名族、刻意不匹配：
    // MangaHibikiPage 等含 hibiki 文件名的类（本轮不 git mv，半径控制）、
    // kMagpieHibikiProfilePrefix（值 'Hibiki: ' 是 Magpie 配置持久化契约）、
    // 'runningHibikiProcesses'（update-handoff JSON wire 键）。
    name: 'Hibiki*-类名族',
    regex: RegExp(r'(?<![A-Za-z0-9])Hibiki[A-Z]'),
  ),
  _ForbiddenPattern(
    // W1：SQL 表 hibiki_paired_peers 已在 v69 迁移改名 fushi_paired_peers。
    // 旧表名只允许活在 fushi_core 的 v69 ALTER TABLE RENAME 迁移步里。
    name: 'hibiki_paired_peers',
    regex: RegExp('hibiki_paired_peers'),
    allowed: <String, String>{
      'packages/fushi_core/lib/src/database/database.dart':
          'v69 迁移步 ALTER TABLE hibiki_paired_peers RENAME TO '
              'fushi_paired_peers 及其 _tableExists 守卫：读旧库做一次性改名的'
              '迁移代码，旧表名是必要输入。',
    },
  ),
  _ForbiddenPattern(
    // W1：主库文件已是 fushi.db（fushiDatabaseFileName）。旧文件名只允许活在
    // 「读旧数据的迁移代码」里：开库前一次性改名 + 老归档条目名回退。
    name: 'hibiki.db',
    regex: RegExp(r'hibiki\.db'),
    allowed: <String, String>{
      'packages/fushi_core/lib/src/database/database.dart':
          'legacyHibikiDatabaseFileName 常量：_openDb 打开任何连接前把 '
              'hibiki.db(+wal/shm) 一次性改名成 fushi.db 的迁移输入。',
      'lib/src/migration/migration_manifest.dart':
          '_dbEntryNames 的 legacy 候选：老 Hibiki app 导出的迁移归档条目名'
              '（wire 冻结），读旧归档必需。',
    },
  ),
];

// ---------------------------------------------------------------------------
// W6：native 目录与残余构建标识改名（native/hibiki_torrent→native/fushi_torrent、
// native/hoshidicts→native/fushidicts + 内层 hoshidicts_{src,include,external}→
// fushidicts_*）。这组禁的是**路径/构建标识形态**，与上面的代码位组不同：
// 扫描面覆盖构建脚本、workflow、docs/agent、native 自树、包与测试，注释**也算**
// （路径引用大多活在注释里，注释里的旧路径同样把人带去不存在的目录）。
//
// 刻意不禁（不是路径形态，是冻结契约/上游对照面）：
//   * 内部静态库 target `hoshidicts`、`hoshi::` 命名空间/`HOSHI_EXPORT` 宏；
//   * 公共头子目录 `fushidicts_include/hoshidicts/`（源码 #include "hoshidicts/*"）；
//   * `.hoshidicts_1` 磁盘分片名（词典持久化契约）；
//   * hibiki_torrent 内层文件名（hibiki_torrent.h / hibiki_torrent_ffi.cpp /
//     hibiki_torrent_bindings.dart）与旧 DLL 加载回退名 hibiki_torrent_ffi.dll；
//   * `native-hoshidicts-gate.yml` 文件名（连字符形态，galgame_hook 注释引用）。
// 豁免（不进扫描面）：docs/bugs|specs|reviews|plans 历史文档、
// native/fushidicts/UPSTREAM.md（上游出处 + 新旧对照表，见下方自证测试）、
// fushidicts_external/ vendored pristine 树、构建产物目录、git 历史。
// ---------------------------------------------------------------------------

final List<_ForbiddenPattern> _forbiddenPathForms = <_ForbiddenPattern>[
  _ForbiddenPattern(
    name: 'native/hibiki_torrent 路径',
    regex: RegExp(r'native[/\\]hibiki_torrent'),
  ),
  _ForbiddenPattern(
    name: 'packages/hibiki_torrent 路径',
    regex: RegExp(r'packages[/\\]hibiki_torrent'),
  ),
  _ForbiddenPattern(
    name: 'native/hoshidicts 路径',
    regex: RegExp(r'native[/\\]hoshidicts'),
  ),
  _ForbiddenPattern(
    name: 'hoshidicts_{src,include,external,build} 目录名',
    regex: RegExp('hoshidicts_(?:src|include|external|build)'),
  ),
  _ForbiddenPattern(
    name: 'HOSHI_ROOT/HOSHI_SRC CMake 变量',
    regex: RegExp('HOSHI_(?:ROOT|SRC)'),
  ),
  _ForbiddenPattern(
    name: 'hoshi-tests CI 构建目录',
    regex: RegExp('hoshi-tests'),
  ),
  _ForbiddenPattern(
    name: 'add_hoshi_test ctest 注册函数',
    regex: RegExp('add_hoshi_test'),
  ),
  _ForbiddenPattern(
    name: 'HIBIKI_TORRENT_LIB 测试环境变量',
    regex: RegExp('HIBIKI_TORRENT_LIB'),
  ),
];

/// 路径形态组的扫描根（相对 `hibiki/`；目录或单文件皆可）。
const List<String> _pathFormScanRoots = <String>[
  '../.github/workflows',
  '../native/fushi_torrent',
  '../native/fushidicts',
  '../packages/fushi_torrent',
  '../packages/fushi_dictionary',
  '../docs/agent',
  '../docs/readme',
  '../tool',
  '../tools',
  '../CLAUDE.md',
  '../README.md',
  '../README.zh-CN.md',
  'CLAUDE.md',
  'lib',
  'test',
  'tool',
  'windows',
  'linux',
  'android/app/build.gradle',
  'android/app/src',
  'ios/Runner.xcodeproj',
  'macos/Runner/Configs',
];

/// 只读文本类扩展（避免撞上二进制夹具/产物）。
const Set<String> _pathFormScanExtensions = <String>{
  '.dart',
  '.yaml',
  '.yml',
  '.md',
  '.gradle',
  '.ps1',
  '.sh',
  '.bat',
  '.py',
  '.mjs',
  '.js',
  '.cmake',
  '.txt',
  '.h',
  '.hpp',
  '.cpp',
  '.cc',
  '.pbxproj',
  '.xcconfig',
  '.kt',
  '.java',
  '.swift',
};

bool _pathFormExcluded(String normalizedPath) {
  // vendored pristine 树 / 构建产物 / 工具缓存不属于我们的命名域。
  for (final String segment in <String>[
    '/fushidicts_external/',
    '/.dart_tool/',
    '/build/',
    '/prebuilt/',
    '/.git/',
  ]) {
    if (normalizedPath.contains(segment)) return true;
  }
  // 上游出处 + 新旧对照表（存活性由下方自证测试守着）。
  if (normalizedPath.endsWith('native/fushidicts/UPSTREAM.md')) return true;
  // 本守卫自身（禁模式字面量所在地）。
  if (normalizedPath.endsWith('test/tools/fushi_rename_guard_test.dart')) {
    return true;
  }
  return false;
}

Iterable<File> _pathFormScanFiles() sync* {
  for (final String root in _pathFormScanRoots) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(root);
    if (type == FileSystemEntityType.file) {
      yield File(root);
      continue;
    }
    expect(type, FileSystemEntityType.directory,
        reason: '路径形态扫描根缺失：$root（目录被改名/移动了？）');
    yield* Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) {
      final String path = _normalize(f.path);
      final int dot = path.lastIndexOf('.');
      final String ext = dot >= 0 ? path.substring(dot) : '';
      return _pathFormScanExtensions.contains(ext);
    });
  }
}

/// 扫描根（相对 `hibiki/`，即 flutter test 的 cwd）。
const List<String> _scanRoots = <String>[
  'lib',
  '../packages/fushi_core/lib',
  '../packages/fushi_dictionary/lib',
  '../packages/fushi_anki/lib',
  '../packages/fushi_audio/lib',
  '../packages/fushi_platform/lib',
  '../packages/fushi_torrent/lib',
];

String _normalize(String path) => path.replaceAll('\\', '/');

/// `lib/...` / `../packages/<pkg>/lib/...` 形式的归一路径（白名单键的基准）。
String _guardPath(String rootSpec, String filePath) {
  final String normalized = _normalize(filePath);
  final String marker = _normalize(rootSpec).replaceFirst('../', '');
  final int idx = normalized.indexOf(marker);
  return idx >= 0 ? normalized.substring(idx) : normalized;
}

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

void main() {
  // 每个文件只做一次注释剥离，缓存给两个测试复用（guardPath → masked source）。
  final Map<String, String> maskedByGuardPath = <String, String>{};

  setUpAll(() {
    for (final String root in _scanRoots) {
      final Directory dir = Directory(root);
      expect(dir.existsSync(), isTrue, reason: '扫描根缺失：$root（包被改名/移动了？）');
      for (final File f in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))) {
        maskedByGuardPath[_guardPath(root, f.path)] =
            maskCommentsAndScriptLines(f.readAsStringSync());
      }
    }
  });

  test('旧代号在代码位（剥注释后）零残留', () {
    final List<String> violations = <String>[];
    for (final _ForbiddenPattern pattern in _forbidden) {
      for (final MapEntry<String, String> entry in maskedByGuardPath.entries) {
        final String guardPath = entry.key;
        if (pattern.allowed.keys
            .any((String suffix) => guardPath.endsWith(suffix))) {
          continue; // 豁免文件；其存活性由下面的过期检测负责。
        }
        final String masked = entry.value;
        for (final RegExpMatch m in pattern.regex.allMatches(masked)) {
          violations
              .add('[${pattern.name}] $guardPath:${_lineOf(masked, m.start)} '
                  '→ ${m.group(0)}');
        }
      }
    }
    expect(violations, isEmpty,
        reason: '发现旧代号代码位残留（注释不算；如属冻结契约请按文件+模式加白名单并写理由）：\n'
            '${violations.join('\n')}');
  });

  test('白名单无过期豁免（残留清掉后必须同步删豁免条目）', () {
    final List<String> stale = <String>[];
    for (final _ForbiddenPattern pattern in _forbidden) {
      for (final MapEntry<String, String> entry in pattern.allowed.entries) {
        final Iterable<String> masked = maskedByGuardPath.entries
            .where((MapEntry<String, String> e) => e.key.endsWith(entry.key))
            .map((MapEntry<String, String> e) => e.value);
        if (masked.isEmpty) {
          stale.add('[${pattern.name}] ${entry.key}（文件不存在）');
          continue;
        }
        if (!masked.any(pattern.regex.hasMatch)) {
          stale.add('[${pattern.name}] ${entry.key}（已无命中）');
        }
      }
    }
    expect(stale, isEmpty,
        reason: '白名单条目已无真实命中，请删除对应豁免（防止白名单退化成盲区）：\n'
            '${stale.join('\n')}');
  });

  test('W6：旧 native 路径/构建标识零残留（构建脚本+workflow+docs+测试，注释也算）', () {
    final List<String> violations = <String>[];
    for (final File f in _pathFormScanFiles()) {
      final String path = _normalize(f.path);
      if (_pathFormExcluded(path)) continue;
      final String source = f.readAsStringSync();
      for (final _ForbiddenPattern pattern in _forbiddenPathForms) {
        for (final RegExpMatch m in pattern.regex.allMatches(source)) {
          violations.add('[${pattern.name}] $path:${_lineOf(source, m.start)} '
              '→ ${m.group(0)}');
        }
      }
    }
    expect(violations, isEmpty,
        reason: '发现旧 native 路径/构建标识残留（W6 已改名 native/fushi_torrent、'
            'native/fushidicts + fushidicts_{src,include,external}；历史文档走 '
            'docs/bugs|specs|reviews|plans，不该出现在这些活跃面里）：\n'
            '${violations.join('\n')}');
  });

  test('W6 豁免自证：UPSTREAM.md 仍记载旧目录形态（否则把它移回扫描面）', () {
    final String upstream =
        File('../native/fushidicts/UPSTREAM.md').readAsStringSync();
    expect(
        _forbiddenPathForms
            .any((_ForbiddenPattern p) => p.regex.hasMatch(upstream)),
        isTrue,
        reason: 'UPSTREAM.md 已无任何旧目录/标识命中——它的扫描面豁免过期了，'
            '请删掉 _pathFormExcluded 里的对应排除，防止豁免退化成盲区。');
  });
}
