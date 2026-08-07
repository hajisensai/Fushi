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
