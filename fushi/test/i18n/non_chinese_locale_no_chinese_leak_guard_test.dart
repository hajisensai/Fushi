import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/i18n_sync.dart';

/// 守卫 BUG-4505：非中文界面里冒出简体中文。
///
/// 事故：系统语言英文、界面选日语，打开视频页弹出的 Anime4K 首次提示是简体中文
/// （`video_shader_first_use_title` / `_body`）；ar / de / es / fr / id / it / ko / nl /
/// pt-BR / ru / th / tr / vi 同样。同批还有 `video_shader_import_from_mpv_hint`、
/// `game_audio_resource_id`、`game_audio_fallback_disabled_missing`、
/// `download_subscription_start_episode`，ja / ko 的 `sync_err_not_paired` 里写着
/// 「Fushi 互联」，ko 的 `skip_action_seconds` 是「秒」。
///
/// 根因：`tool/i18n_sync.dart` 无参补全模式把缺的 key 一律用 **zh-CN 值**填进所有语言
/// （旧 `_syncMissing` 的 `zhCnJson[key] ?? baseJson[key]`），没翻译的 key 于是以中文
/// 而不是英文出现在日语 / 德语等界面。修法：只有 zh-* 借 zh-CN，其余语言借英文
/// （[missingKeyFillValue]），并把已经漏进去的值逐语言改成译文（`--set`）。
///
/// 本守卫钉两条：
///  1. 补全规则本身（[missingKeyFillValue]）。
///  2. 现存 json：非 CJK 语言与 ko 的值里，汉字只能是英文原文里本来就有的（例句、
///     「漢字[かな]」示例、萌娘百科之类专名）；ja 的值里不得出现日文不用的简体字形
///     （英文原文本来就有的除外，如繁简示例「这个 ↔ 這個」）。
const List<String> _hanForbiddenLocales = <String>[
  'ar',
  'de',
  'es',
  'fr',
  'id',
  'it',
  'ko',
  'nl',
  'pt-BR',
  'ru',
  'th',
  'tr',
  'vi',
];

/// 只在简体中文里出现、日文用另一字形的字（日文对应：這 們 譲 説 還 試 従 該 時 関
/// 設 動 載 選 択 録 進 発 現 給 対 様 習 頁 書 読 詞 顕 変 聴 訳 過 頻 資 開 撃 視 図
/// 応 連 網 音頻→音声）。刻意不收日文也用的同形字（机 后 与 没 区 号 等）。
const String _simplifiedOnlyChars =
    '这们让说还么试从该时关设动载选择录进发现给对样习页书读词显变听译过频资开击视图应联网';

final RegExp _han = RegExp(r'[㐀-䶿一-鿿豈-﫿]');

Map<String, dynamic> _readLocale(String locale) {
  final String name = locale == 'en'
      ? 'strings.i18n.json'
      : 'strings_$locale.i18n.json';
  final File file = File(p.join(Directory.current.path, 'lib', 'i18n', name));
  expect(file.existsSync(), isTrue, reason: '$name 应存在于 ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Set<String> _hanCharsOf(String value) =>
    _han.allMatches(value).map((RegExpMatch m) => m.group(0)!).toSet();

void main() {
  group('missingKeyFillValue：缺 key 时借哪种语言（BUG-4505 根因）', () {
    final Map<String, dynamic> base = <String, dynamic>{
      'k': 'Try Anime4K image enhancement',
    };
    final Map<String, dynamic> zhCn = <String, dynamic>{'k': '试试 Anime4K 画质增强'};

    test('非中文语言一律借英文，不借 zh-CN', () {
      for (final String locale in <String>['ja', 'ko', 'de', 'pt-BR', 'ar']) {
        expect(
          missingKeyFillValue(locale, 'k', base, zhCn),
          'Try Anime4K image enhancement',
          reason: '$locale 缺 key 时应显示英文，而不是用户没选的简体中文',
        );
      }
    });

    test('中文语言借 zh-CN，zh-CN 也没有时退回英文', () {
      expect(missingKeyFillValue('zh-HK', 'k', base, zhCn), '试试 Anime4K 画质增强');
      expect(
        missingKeyFillValue('zh-HK', 'k', base, <String, dynamic>{}),
        'Try Anime4K image enhancement',
      );
    });
  });

  group('现存译文不含漏进来的中文', () {
    late Map<String, dynamic> en;
    setUpAll(() {
      en = _readLocale('en');
    });

    String enOf(String key) {
      final dynamic value = en[key];
      return value is String ? value : '';
    }

    for (final String locale in _hanForbiddenLocales) {
      test('$locale：汉字只能来自英文原文', () {
        final Map<String, dynamic> json = _readLocale(locale);
        final List<String> leaks = <String>[];
        json.forEach((String key, dynamic value) {
          if (value is! String) return;
          final Set<String> extra = _hanCharsOf(
            value,
          ).difference(_hanCharsOf(enOf(key)));
          if (extra.isNotEmpty) leaks.add('$key: $value');
        });
        expect(leaks, isEmpty, reason: '$locale 里出现了英文原文没有的汉字');
      });
    }

    test('ja：不含日文不用的简体字形', () {
      final Map<String, dynamic> json = _readLocale('ja');
      final Set<String> simplified = _simplifiedOnlyChars.split('').toSet();
      final List<String> leaks = <String>[];
      json.forEach((String key, dynamic value) {
        if (value is! String) return;
        final Set<String> hits = _hanCharsOf(
          value,
        ).intersection(simplified).difference(_hanCharsOf(enOf(key)));
        if (hits.isNotEmpty) leaks.add('$key: $value  (${hits.join()})');
      });
      expect(leaks, isEmpty, reason: 'ja 里出现了简体中文字形，多半是 zh-CN 值漏了进来');
    });
  });
}
