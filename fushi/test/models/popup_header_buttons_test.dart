import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/popup_header_buttons.dart';

/// 拍板台 b1JDe8McbS：查词弹窗词条头按钮排布（顺序 / 隐藏 / 额外制卡按钮）的存储模型。
void main() {
  List<String> wires(List<PopupHeaderButton> b) => <String>[
    for (final PopupHeaderButton x in b) x.wire,
  ];

  test('出厂排布 = 改动前 popup.js 的固定顺序，且是 isDefault', () {
    final PopupHeaderButtonsConfig d = PopupHeaderButtonsConfig.defaults;
    expect(d.order, <String>[
      'audio',
      'favorite',
      'srs',
      'mine',
      'openAnki',
      'context',
      'crossAppAudio',
      'advanced',
    ]);
    expect(d.isDefault, isTrue);
    expect(PopupHeaderButtonsConfig.parse(null), d);
    expect(PopupHeaderButtonsConfig.parse(''), d);
    expect(PopupHeaderButtonsConfig.parse('{not json'), d);
    expect(PopupHeaderButtonsConfig.parse('[1,2]'), d);
  });

  test('normalized：丢未知 / 重复槽位，缺的内置按钮插回出厂位置', () {
    final PopupHeaderButtonsConfig c = const PopupHeaderButtonsConfig(
      order: <String>['advanced', 'mine', 'bogus', 'mine', 'audio'],
      hidden: <String>{'favorite', 'bogus'},
    ).normalized();
    // favorite / srs 原本跟在 audio 后面；openAnki 等跟在 mine 后面。
    expect(c.order, <String>[
      'advanced',
      'mine',
      'openAnki',
      'context',
      'crossAppAudio',
      'audio',
      'favorite',
      'srs',
    ]);
    expect(c.hidden, <String>{'favorite'});
    expect(c.order.toSet(), wires(PopupHeaderButton.values).toSet());
  });

  test('新增方案插在最后一颗制卡按钮之后；删除方案顺带清掉它的槽位与隐藏', () {
    const PopupMiningScheme kana = PopupMiningScheme(
      id: 'kana',
      label: '假名',
      fieldTemplates: <String, String>{'Expression': '{reading}'},
    );
    const PopupMiningScheme sentence = PopupMiningScheme(
      id: 'sent',
      label: '句子',
      deckName: 'Sentences',
      omitImage: true,
    );
    PopupHeaderButtonsConfig c = PopupHeaderButtonsConfig.defaults
        .withScheme(kana)
        .withScheme(sentence);
    expect(c.order.sublist(3, 6), <String>[
      'mine',
      'scheme:kana',
      'scheme:sent',
    ]);
    expect(c.isDefault, isFalse);

    c = c.withHidden('scheme:kana', true).withoutScheme('kana');
    expect(c.order.contains('scheme:kana'), isFalse);
    expect(c.hidden, isEmpty);
    expect(c.schemes.single.id, 'sent');
  });

  test('withScheme 按 id 替换而不是追加', () {
    const PopupMiningScheme a = PopupMiningScheme(id: 'x', label: 'A');
    final PopupHeaderButtonsConfig c = PopupHeaderButtonsConfig.defaults
        .withScheme(a)
        .withScheme(a.copyWith(label: 'B'));
    expect(c.schemes.single.label, 'B');
    expect(
      c.order.where((String s) => s == 'scheme:x').length,
      1,
      reason: '替换不能多出一个槽位',
    );
  });

  test('moved 按最终下标移动', () {
    final PopupHeaderButtonsConfig c = PopupHeaderButtonsConfig.defaults.moved(
      7,
      0,
    );
    expect(c.order.first, 'advanced');
    expect(c.order[4], 'mine');
  });

  test('encode / parse 往返，坏方案逐个丢弃', () {
    final PopupHeaderButtonsConfig c = PopupHeaderButtonsConfig.defaults
        .withScheme(
          const PopupMiningScheme(
            id: 'kana',
            label: '假名',
            deckName: 'Kana',
            fieldTemplates: <String, String>{
              'Expression': '{reading}',
              'Hint': '',
            },
            omitAudio: true,
          ),
        )
        .withHidden('favorite', true)
        .moved(0, 2);
    expect(PopupHeaderButtonsConfig.parse(c.encode()), c);

    final Map<String, Object?> raw = c.toJson();
    raw['schemes'] = <Object?>[
      ...(raw['schemes']! as List<Object?>),
      <String, Object?>{'label': 'no id'},
      42,
    ];
    final PopupHeaderButtonsConfig back = PopupHeaderButtonsConfig.parse(
      jsonEncode(raw),
    );
    expect(back.schemes.length, 1);
  });

  test('toPopupJson：方案按槽位给出按钮名与单次制卡覆盖项', () {
    final PopupHeaderButtonsConfig c = PopupHeaderButtonsConfig.defaults
        .withScheme(
          const PopupMiningScheme(
            id: 'kana',
            label: '假名',
            fieldTemplates: <String, String>{'Expression': '{reading}'},
            omitImage: true,
          ),
        );
    final Map<String, Object?> js = c.toPopupJson();
    expect(js['order'], c.order);
    expect(js['schemes'], <String, Object?>{
      'scheme:kana': <String, Object?>{
        'label': '假名',
        'overrides': <String, Object?>{
          'omitImage': true,
          'fieldTemplates': <String, String>{'Expression': '{reading}'},
        },
      },
    });
  });
}
