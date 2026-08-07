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
    name: 'setTtu/getTtu',
    regex: RegExp(r'\b(?:set|get)Ttu'),
  ),
  _ForbiddenPattern(
    // W2-1：阅读器源持久化键已是 'reader_fushi'（kReaderSourcePersistedKey），
    // 存量行由 v70 迁移改写（preferences/profile_settings/media_items 三处）。
    name: 'reader_ttu',
    regex: RegExp('reader_ttu'),
    allowed: <String, String>{
      'packages/fushi_core/lib/src/database/database.dart':
          'v16 阶梯 _kLegacyUidPrefix（reader_ttu/hoshi://book/）与 v70 改写步的'
              '旧前缀输入：读旧库做一次性改写的迁移代码，旧字面量是必要输入。',
    },
  ),
  _ForbiddenPattern(
    // W2-1：pref shortKey 的死前缀 ttu_ 已剥除（'ttu_font_size' → 'font_size'
    // 等 27 键），存量由 v70 迁移改写。引号锚定只抓字符串字面量形态；负向前瞻
    // 放行冻结身份模块 ttu_sanitize.dart 的相对 import（bookKey 编码本体，
    // ~ttu-star~ 哨兵落盘，勿改）。
    name: "'ttu_ shortKey 前缀",
    regex: RegExp(r"'ttu_(?!sanitize\.dart')"),
    allowed: <String, String>{
      'packages/fushi_core/lib/src/database/database.dart':
          '历史 SQL 列名 ttu_book_id / ttu_char_offset（v16/v24 迁移阶梯输入）'
              '与 v70 剥前缀步的旧前缀输入，只活在迁移代码里。',
    },
  ),
  _ForbiddenPattern(
    // W2-1：ttu 词首 camel 符号（ttuFontSize 等 22 个 getter → reader*、
    // ttuRegex → readerRegex、ttuCharOffset → exactCharOffset）。冻结的
    // TtuProgress/sanitizeTtuFilename 是词中 Ttu 形态，刻意不匹配。
    name: 'ttu*-camel 符号',
    regex: RegExp(r'\bttu[A-Z]'),
    allowed: <String, String>{
      'packages/fushi_core/lib/src/database/database.dart':
          "legacy 书签 JSON 的 'ttuBookId' wire 键及其局部变量（迁移代码），"
              '命名跟随冻结 wire 本名。',
    },
  ),
  _ForbiddenPattern(
    // P6-4b：Sasayaki* → SubtitleRematch*/sentenceAudio*；W2-2：四个持久化冻结
    // 点全解冻（sasayaki:// scheme / sasayakiColor JSON 键 /
    // custom_theme_sasayaki_color 偏好键 → fushi_core v71 迁移改写；
    // {sasayaki-audio} handlebars 别名 → BaseAnkiRepository 载入期迁移改写）。
    name: 'sasayaki',
    regex: RegExp('sasayaki', caseSensitive: false),
    allowed: <String, String>{
      'packages/fushi_core/lib/src/database/database.dart':
          "v71 迁移步的旧值输入：'sasayaki://' scheme 前缀、'sasayakiColor' "
              "JSON 键、'custom_theme_sasayaki_color' 偏好键。读旧库做一次性"
              '改写的迁移代码，旧字面量是必要输入。',
      'packages/fushi_anki/lib/src/base_anki_repository.dart':
          "'{sasayaki-audio}' handlebars 旧别名：loadSettings 载入期一次性改写"
              '为 {sentence-audio} 的迁移输入（SharedPreferences 无版本阶梯，'
              '载入期改写即迁移通道）。',
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
    // W2-4：导出目录已是 fushiExport（export_directory.dart），存量旧目录由
    // prepareExportDirectoryAt 启动就地改名。
    name: 'hibikiExport',
    regex: RegExp('hibikiExport', caseSensitive: false),
    allowed: <String, String>{
      'lib/src/storage/export_directory.dart':
          'kLegacyExportDirectoryName：启动就地改名迁移的旧目录名输入。',
      'lib/src/storage/app_paths.dart': '数据根搬迁白名单的双名条目：改名失败留在旧名的存量目录仍须随迁移'
          '搬走，否则数据分家。',
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
    // MangaHibikiPage 等含 hibiki 文件名的类（W4 才 git mv，半径控制）。
    name: 'Hibiki*-类名族',
    regex: RegExp(r'(?<![A-Za-z0-9])Hibiki[A-Z]'),
  ),
  _ForbiddenPattern(
    // W2-6：update-handoff JSON wire 键已是 'runningFushiProcesses'（写侧只写
    // 新键）；旧键只允许活在读侧回退（真实跨版本 wire：hibiki→fushi 更新桥时代
    // 的旧二进制写 marker、新版读，清理条件锚在 update_handoff.dart 注释）。
    name: 'runningHibikiProcesses',
    regex: RegExp('runningHibikiProcesses'),
    allowed: <String, String>{
      'lib/src/utils/misc/update_handoff.dart':
          'fromJson 的旧键读侧回退：旧 Hibiki 过渡版写的 marker 在升级后由新版'
              '读取，是唯一会见到旧键的窗口；写侧只写新键。',
    },
  ),
  _ForbiddenPattern(
    // W2-5：Magpie 配置 profile 名前缀已是 'Fushi: '
    // （kMagpieFushiProfilePrefix）；存量 'Hibiki: ' 条目由启动对账
    // （magpieConfigWithLegacyProfilePrefixRenamed）就地改名。
    name: "'Hibiki: ' Magpie 前缀",
    regex: RegExp("'Hibiki: '"),
    allowed: <String, String>{
      'lib/src/mining/magpie_upscaling.dart':
          'kMagpieLegacyProfilePrefix：启动就地改名迁移的旧前缀输入，只允许'
              '该改名函数消费。',
    },
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
}
