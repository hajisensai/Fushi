/// 词典样式预览用的样例词条。
///
/// 形状必须与生产契约逐字段一致——预览跑的是真 `popup.js`，字段名错一个就是
/// 那一段静默不渲染，而用户会以为是自己的样式没生效。契约真源：C++
/// `native/fushidicts/fushidicts_src/popup_json.cpp:67 build_popup_json()`，
/// Dart 回落 `dictionary_popup_webview.dart:2357 buildLookupEntriesJson()`。
///
/// 这一条刻意把每个可调部位都点亮：振假名、表达标签、去屈折链、两组频率、
/// 两组音调（数字位 + IPA）、两本词典分组（其一多义项走 ol/li、其一结构化内容）、
/// 释义标签。少点亮一个，那个部位在预览里就调不了。
library;

const List<Map<String, Object>> kDictStylePreviewEntries =
    <Map<String, Object>>[
  <String, Object>{
    'expression': '食べる',
    'reading': 'たべる',
    'matched': '食べさせられた',
    // 生产端恒为空数组；只有 Anki 导出的音调分类会读它。
    'rules': <String>[],
    'deinflectionTrace': <Map<String, String>>[
      <String, String>{
        'name': '-させる',
        'description': '使役形。動詞の未然形に接続する。',
      },
      <String, String>{
        'name': '-られる',
        'description': '受身形。使役の未然形に接続する。',
      },
      <String, String>{
        'name': '-た',
        'description': '過去・完了。連用形に接続する。',
      },
    ],
    'glossaries': <Map<String, Object>>[
      // 同名词典的多条会被合并成一个 details.glossary-group，两条以上才走
      // <ol><li> 多义项分支——预览要能演示那个分支。
      <String, Object>{
        'dictionary': 'JMdict',
        'content': <String>['to eat'],
        'definitionTags': 'v1 vt ichi news',
        'termTags': 'ichi1 news1',
      },
      <String, Object>{
        'dictionary': 'JMdict',
        'content': <String>[
          'to live on (e.g. a salary)',
          'to live off',
          'to subsist on',
        ],
        'definitionTags': 'v1 vt col',
        'termTags': 'ichi1 news1',
      },
      // 结构化内容分支（单条 → div，不走 ol/li）。
      <String, Object>{
        'dictionary': '大辞林',
        'content': <String, Object>{
          'type': 'structured-content',
          'content': <Map<String, Object>>[
            <String, Object>{
              'tag': 'span',
              'content': '食物を口に入れ、かんで飲みこむ。',
            },
            <String, Object>{
              'tag': 'div',
              'content': <Map<String, Object>>[
                <String, Object>{'tag': 'span', 'content': '朝食を食べる'},
              ],
            },
          ],
        },
        'definitionTags': '動下一',
        'termTags': '常用漢字',
      },
    ],
    'frequencies': <Map<String, Object>>[
      <String, Object>{
        'dictionary': 'BCCWJ',
        'frequencies': <Map<String, Object>>[
          <String, Object>{'value': 412, 'displayValue': '412'},
        ],
      },
      <String, Object>{
        'dictionary': 'JPDB',
        'frequencies': <Map<String, Object>>[
          <String, Object>{'value': 850, 'displayValue': '850㋕'},
        ],
      },
    ],
    'pitches': <Map<String, Object>>[
      // 数字位 → .pronunciation-mora（拍数取自 entry 级 reading，不是这里）。
      <String, Object>{
        'dictionary': 'NHK',
        'pitchPositions': <int>[2],
        'patterns': <String>[],
        'transcriptions': <String>[],
      },
      <String, Object>{
        'dictionary': 'IPA',
        'pitchPositions': <int>[],
        'patterns': <String>[],
        'transcriptions': <String>['tabeɾɯ'],
      },
    ],
  },
];
