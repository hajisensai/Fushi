import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show canonicalDictionaryLanguageTag;

import 'package:fushi/src/ops/op_describe_kit.dart';

/// 词典、推荐包与 Anki 的操作描述（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §4）。路由见 `ctl_dictionary_routes.dart` / `ctl_dictionary_pack_routes.dart`。
///
/// 撤销形态：
/// * 词典启停 / 排序 / 显示名 / 内容语言 / 汉字部分 = 快照：执行前从 `dict.list`
///   读这一本（及所在分区的顺序），撤销经同一个 PUT 写回；
/// * 导入 / 安装推荐词典 = 删掉这次新增的那几本（名字取自结果 / 执行前后差集）；
/// * 推荐包下载 ↔ 取消下载互为反向；取消词典任务的撤销 = 按原目标重新发起。
/// * 删除词典（删词典数据目录）、在线更新（旧版本不保留）、推荐包导入（覆盖 /
///   合并数据后重启）、Anki 制卡 / 同步 / 待发队列（写到外部 Anki、无删卡路由）= 不可逆。
///
/// 查词不受模块门控（`ModuleId.lookup` 只关查词页入口），这里也不挂可用性谓词。
List<OpDescription> describeDictionaryOps(OpDescribeKit kit) => <OpDescription>[
  // ── 推荐包 ───────────────────────────────────────────────────────────────
  const OpDescription(
    id: 'dict.pack.status',
    method: 'GET',
    pattern: '/api/admin/dictionary-pack',
    summary:
        'Status of the recommended pack (dictionaries + pronunciation audio, '
        'about 9.5 GB): download stage, progress, whether it is ready to import.',
  ),
  OpDescription(
    id: 'dict.pack.download',
    method: 'POST',
    pattern: '/api/admin/dictionary-pack/download',
    summary:
        'Start (or resume) downloading the recommended pack in the background; '
        'poll dict.pack.status. Undo cancels the download (the partial file is '
        'kept for resuming).',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.boolean(
        'wait',
        description: 'Block until the download finishes (can take hours).',
      ),
    ],
    undo: kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => const <String, Object?>{},
      inverse: (Map<String, Object?> payload) =>
          kit.callRoute('POST', '/api/admin/dictionary-pack/cancel'),
      describe: (Map<String, Object?> payload) => 'downloading',
    ),
  ),
  OpDescription(
    id: 'dict.pack.cancel',
    method: 'POST',
    pattern: '/api/admin/dictionary-pack/cancel',
    summary:
        'Pause the recommended pack download (the partial file is kept). Undo '
        'resumes it.',
    risk: OpRisk.write,
    undo: kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => const <String, Object?>{},
      inverse: (Map<String, Object?> payload) =>
          kit.callRoute('POST', '/api/admin/dictionary-pack/download'),
      describe: (Map<String, Object?> payload) => 'paused',
    ),
  ),
  // 不可逆：删除盘上的半截下载文件（可能几个 GB），只能重新下载。
  const OpDescription(
    id: 'dict.pack.discard',
    method: 'DELETE',
    pattern: '/api/admin/dictionary-pack',
    summary:
        'Delete the paused, partially downloaded recommended pack file from '
        'disk.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the partial download.',
      ),
    ],
  ),
  // 不可逆：按备份导入编排把整包导入（replace 覆盖现有数据），完成后 app 重启。
  const OpDescription(
    id: 'dict.pack.import',
    method: 'POST',
    pattern: '/api/admin/dictionary-pack/import',
    summary:
        'Import the downloaded recommended pack (a Fushi backup) by merging or '
        'replacing data; the app restarts when done.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'mode',
        description: 'merge keeps existing data; replace overwrites it.',
        required: true,
        enumValues: <String>['merge', 'replace'],
      ),
      OpParam.stringList(
        'categories',
        description: 'Backup categories to import; default all in the pack.',
      ),
      OpParam.boolean(
        'importSettings',
        description: 'Also import settings from the pack.',
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed importing the pack.',
      ),
    ],
  ),

  // ── 词典仓库 ─────────────────────────────────────────────────────────────
  const OpDescription(
    id: 'dict.list',
    method: 'GET',
    pattern: '/api/admin/dictionaries',
    summary:
        'List installed dictionaries by type and order (name, display name, '
        'enabled, revision, whether online-updatable, language).',
    params: <OpParam>[
      OpParam.string(
        'type',
        description: 'Only this dictionary type.',
        enumValues: <String>['term', 'kanji', 'frequency', 'pitch'],
      ),
    ],
  ),
  OpDescription(
    id: 'dict.set',
    method: 'PUT',
    pattern: '/api/admin/dictionaries/:name',
    summary:
        'Change one dictionary: enable / disable, move to position N within its '
        'language group of its type section, rename (display name), set content '
        'language (a changed group puts it last in the new group), and for term '
        'dictionaries with embedded kanji the kanji part switch / position.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'name',
        description: 'Dictionary name or display name from dict.list.',
        required: true,
        inPath: true,
      ),
      OpParam.boolean('enabled', description: 'true = show in lookups.'),
      OpParam.integer(
        'position',
        description:
            '1-based position within its language group (same language) of its '
            'type section; other language groups keep their order.',
      ),
      OpParam.string('displayName', description: 'New display name.'),
      OpParam.boolean(
        'resetDisplayName',
        description: 'true = use the name from the package again.',
      ),
      OpParam.string(
        'language',
        description: 'Content language (BCP-47, e.g. ja); auto = from package.',
      ),
      OpParam.boolean(
        'kanjiEnabled',
        description:
            'Kanji part switch of a term dictionary with embedded kanji.',
      ),
      OpParam.integer(
        'kanjiPosition',
        description:
            '1-based position within its language group of the kanji section.',
      ),
    ],
    undo: _dictionarySetUndo(kit),
  ),
  // 不可逆：删词典元数据并删除词典数据目录（导入产物），要恢复只能用原文件重新导入。
  const OpDescription(
    id: 'dict.remove',
    method: 'DELETE',
    pattern: '/api/admin/dictionaries/:name',
    summary: 'Delete an installed dictionary and its imported data.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'name',
        description: 'Dictionary name from dict.list.',
        required: true,
        inPath: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed deleting the dictionary.',
      ),
    ],
  ),
  OpDescription(
    id: 'dict.import',
    method: 'POST',
    pattern: '/api/admin/dictionaries/import',
    summary:
        'Import dictionary files or folders (zip / mdx / dsl / ifo …; .css '
        'files are attached as styles). Undo deletes the dictionaries this '
        'import added.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.stringList(
        'paths',
        description: 'Absolute paths of dictionary files or folders.',
        required: true,
      ),
    ],
    undo: kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => <String, Object?>{
        'names': _stringList(result is Map ? result['added'] : null),
      },
      inverse: (Map<String, Object?> payload) async {
        for (final String name in _stringList(payload['names'])) {
          await _deleteDictionary(kit, name);
        }
        return null;
      },
      describe: (Map<String, Object?> payload) =>
          _stringList(payload['names']).join(', '),
    ),
  ),
  // 不可逆：有新版时下载并以新版本替换已装词典，旧版本不保留。
  const OpDescription(
    id: 'dict.update',
    method: 'POST',
    pattern: '/api/admin/dictionaries/update',
    summary:
        'Check online and update dictionaries to the latest revision (default '
        'all updatable ones) as a background job; poll dict.job.status. The '
        'old revision is replaced.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.stringList(
        'names',
        description: 'Dictionary names from dict.list; default all updatable.',
      ),
      OpParam.boolean('wait', description: 'Block until the job finishes.'),
    ],
  ),
  const OpDescription(
    id: 'dict.recommended.list',
    method: 'GET',
    pattern: '/api/admin/dictionaries/recommended',
    summary:
        'List the recommended dictionary catalog for a learning / gloss '
        'language (key for dict.install, installed, default selection).',
    params: <OpParam>[
      OpParam.string(
        'learning',
        description: 'Learning language code; default ja.',
      ),
      OpParam.string(
        'gloss',
        description: 'Gloss language code; default the UI language.',
      ),
    ],
  ),
  OpDescription(
    id: 'dict.install',
    method: 'POST',
    pattern: '/api/admin/dictionaries/install',
    summary:
        'Download and import recommended dictionaries as a background job '
        '(already installed ones are skipped); poll dict.job.status. Undo '
        'deletes the dictionaries this job installed.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.stringList(
        'names',
        description: 'Catalog keys from dict.recommended.list.',
      ),
      OpParam.boolean(
        'defaults',
        description: 'Install the default selection of the catalog.',
      ),
      OpParam.string(
        'learning',
        description: 'Learning language code; default ja.',
      ),
      OpParam.string(
        'gloss',
        description: 'Gloss language code; default the UI language.',
      ),
      OpParam.boolean('wait', description: 'Block until the job finishes.'),
    ],
    undo: _dictionaryInstallUndo(kit),
  ),
  const OpDescription(
    id: 'dict.job.status',
    method: 'GET',
    pattern: '/api/admin/dictionaries/job',
    summary:
        'Progress of the running dictionary download / import job and results '
        'of the last update / install job.',
  ),
  OpDescription(
    id: 'dict.job.cancel',
    method: 'POST',
    pattern: '/api/admin/dictionaries/job/cancel',
    summary:
        'Cancel the running dictionary download job (not possible once it is '
        'importing). Undo starts the same update / install again.',
    risk: OpRisk.write,
    undo: _dictionaryJobCancelUndo(kit),
  ),
  const OpDescription(
    id: 'dict.search',
    method: 'GET',
    pattern: '/api/admin/dictionaries/search',
    summary:
        'Look up a word in the enabled dictionaries; structured entries '
        '(headword, reading, dictionary, plain-text meanings).',
    params: <OpParam>[
      OpParam.string('term', description: 'Word to look up.', required: true),
      OpParam.integer('limit', description: 'Max entries; default 10.'),
      OpParam.boolean('wildcards', description: 'Treat * and ? as wildcards.'),
      OpParam.integer(
        'maxMeaningChars',
        description: 'Clip each meaning to this many characters; 0 = no clip.',
      ),
      OpParam.string(
        'language',
        description:
            'Lookup language (BCP-47, e.g. zh-CN); Chinese also tries '
            'traditional spellings. Default: the current lookup language.',
      ),
    ],
  ),

  // ── Anki ─────────────────────────────────────────────────────────────────
  const OpDescription(
    id: 'anki.status',
    method: 'GET',
    pattern: '/api/admin/anki',
    summary:
        'Anki backend, deck, note type, whether Anki is reachable and the sync '
        'state.',
    params: <OpParam>[
      OpParam.boolean(
        'probe',
        description: 'Contact Anki to check availability; default true.',
      ),
    ],
  ),
  const OpDescription(
    id: 'anki.deck.list',
    method: 'GET',
    pattern: '/api/admin/anki/decks',
    summary: 'List Anki decks (marks the deck used for mining).',
  ),
  const OpDescription(
    id: 'anki.model.list',
    method: 'GET',
    pattern: '/api/admin/anki/models',
    summary: 'List Anki note types (marks the one used for mining).',
  ),
  // 不可逆：换笔记类型会把字段映射重置成 Lapis 预设（与设置页下拉同语义），用户
  // 自定义的映射没有路由能写回；牌组与笔记类型在同一条路由里。
  const OpDescription(
    id: 'anki.settings.set',
    method: 'PUT',
    pattern: '/api/admin/anki/settings',
    summary:
        'Set the Anki deck and / or note type used for mining. Changing the '
        'note type resets the field mapping to the preset.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string('deck', description: 'Deck name from anki.deck.list.'),
      OpParam.string(
        'model',
        description: 'Note type name from anki.model.list.',
      ),
    ],
  ),
  // 不可逆：卡片写进外部的 Anki（或进待发队列），没有删卡路由。
  const OpDescription(
    id: 'anki.mine',
    method: 'POST',
    pattern: '/api/admin/anki/mine',
    summary:
        'Create an Anki card for a word; missing reading / glossary is filled '
        'from the dictionaries.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'word',
        description: 'Word (expression) for the card.',
        required: true,
      ),
      OpParam.string('reading', description: 'Reading override.'),
      OpParam.string('glossary', description: 'Glossary override (HTML).'),
      OpParam.string('sentence', description: 'Example sentence.'),
      OpParam.string('source', description: 'Source title (document name).'),
      OpParam.object('fields', description: 'Extra card fields {name: value}.'),
      OpParam.boolean(
        'lookup',
        description: 'Fill missing fields from the dictionaries; default true.',
      ),
      OpParam.string(
        'language',
        description:
            'Lookup language (BCP-47, e.g. zh-CN); Chinese also tries '
            'traditional spellings. Default: the current lookup language.',
      ),
      OpParam.boolean(
        'allowDuplicate',
        description: 'Add even if Anki already has this word.',
      ),
    ],
  ),
  const OpDescription(
    id: 'anki.duplicate.check',
    method: 'GET',
    pattern: '/api/admin/anki/duplicate',
    summary: 'Check whether Anki already has a card for this word.',
    params: <OpParam>[
      OpParam.string(
        'expression',
        description: 'Word (expression).',
        required: true,
      ),
      OpParam.string('reading', description: 'Reading.'),
    ],
  ),
  // 不可逆：与 AnkiWeb 双向同步（上传 / 下载整个牌组集合的改动）。
  const OpDescription(
    id: 'anki.sync',
    method: 'POST',
    pattern: '/api/admin/anki/sync',
    summary:
        'Sync the collection with AnkiWeb now (only for the built-in Anki sync '
        'client backend).',
    risk: OpRisk.irreversible,
  ),
  const OpDescription(
    id: 'anki.pending.list',
    method: 'GET',
    pattern: '/api/admin/anki/pending',
    summary:
        'List cards waiting in the send queue (Anki was unreachable or batch '
        'mining).',
    params: <OpParam>[
      OpParam.string(
        'status',
        description: 'Only rows with this status (pending / sending / failed).',
      ),
    ],
  ),
  // 不可逆：把排队的卡发进外部 Anki，发出后没有删卡路由。
  const OpDescription(
    id: 'anki.pending.send',
    method: 'POST',
    pattern: '/api/admin/anki/pending/send',
    summary: 'Send queued cards to Anki now (all, or one by id).',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string('id', description: 'Queue id from anki.pending.list.'),
    ],
  ),
  // 不可逆：真删队列里全部失败的卡（卡片内容随之丢失）。
  const OpDescription(
    id: 'anki.pending.discard-failed',
    method: 'POST',
    pattern: '/api/admin/anki/pending/discard-failed',
    summary: 'Discard every failed card in the send queue.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.userGate(
        'confirm',
        description: 'User confirmed discarding the failed cards.',
      ),
    ],
  ),
  // 不可逆：重置为待发并立即发进外部 Anki。
  const OpDescription(
    id: 'anki.pending.retry',
    method: 'POST',
    pattern: '/api/admin/anki/pending/:id/retry',
    summary: 'Retry one failed queued card (reset and send it to Anki now).',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Queue id from anki.pending.list.',
        required: true,
        inPath: true,
      ),
    ],
  ),
  // 不可逆：真删队列里的一张卡。
  const OpDescription(
    id: 'anki.pending.discard',
    method: 'DELETE',
    pattern: '/api/admin/anki/pending/:id',
    summary: 'Discard one card from the send queue.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'id',
        description: 'Queue id from anki.pending.list.',
        required: true,
        inPath: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed discarding the card.',
      ),
    ],
  ),
];

// ── dict.set 的快照撤销 ───────────────────────────────────────────────────

/// 本次 PUT 动到的字段（快照只抓这些，撤销只写回这些）。
List<String> _touchedDictionaryFields(CtlCall call) => <String>[
  if (call.body['enabled'] != null) 'enabled',
  if (call.body['displayName'] != null || call.body['resetDisplayName'] == true)
    'customDisplayName',
  if (call.body['language'] != null) 'languageOverride',
  if (call.body['kanjiEnabled'] != null) 'kanjiEnabled',
  if (call.body['position'] != null) 'position',
  if (call.body['kanjiPosition'] != null) 'kanjiPosition',
];

/// 分区：`position` 在本类型分区里排（kanji 类型 = 「汉字」分区），`kanjiPosition`
/// 恒在「汉字」分区里排（与路由同语义）。两者都是**语言组内**的位置，快照里存的
/// 名序也只含该词典所在语言组（见 [_dictionarySnapshot]）。
String _sectionOf(Map<String, Object?> dict, String field) =>
    field == 'kanjiPosition' || dict['type'] == 'kanji'
    ? 'kanji'
    : '${dict['type']}';

OpUndo _dictionarySetUndo(OpDescribeKit kit) => _keyedSnapshotUndo(
  keyOf: (CtlCall call) async {
    final Map<String, Object?> target = _resolveDictionary(
      await _listDictionaries(kit),
      call.params['name']!,
    );
    return <String, Object?>{
      'name': target['name'],
      'fields': _touchedDictionaryFields(call),
    };
  },
  read: (Map<String, Object?> key) async =>
      _dictionarySnapshot(await _listDictionaries(kit), key),
  write: (Map<String, Object?> key, Object? old) async {
    final Map<String, Object?> snapshot = Map<String, Object?>.from(
      old! as Map,
    );
    final String name = '${key['name']}';
    final Map<String, Object?> body = <String, Object?>{};
    for (final MapEntry<String, Object?> e in snapshot.entries) {
      switch (e.key) {
        case 'enabled' || 'kanjiEnabled':
          body[e.key] = e.value == true;
        case 'customDisplayName':
          if (e.value == null) {
            body['resetDisplayName'] = true;
          } else {
            body['displayName'] = e.value;
          }
        case 'languageOverride':
          body['language'] = e.value ?? 'auto';
        case 'orders':
          final Map<Object?, Object?> orders = e.value! as Map;
          final List<Map<String, Object?>> list = await _listDictionaries(kit);
          final Map<String, Object?> dict = _resolveDictionary(list, name);
          for (final MapEntry<Object?, Object?> section in orders.entries) {
            final int index = _stringList(section.value).indexOf(name) + 1;
            final bool primary = section.key == _sectionOf(dict, 'position');
            body[primary ? 'position' : 'kanjiPosition'] = index;
          }
      }
    }
    await kit.callRoute(
      'PUT',
      '/api/admin/dictionaries/:name',
      params: <String, String>{'name': name},
      body: body,
    );
  },
  newValue: (CtlCall call, Object? old, Object? result) {
    final Map<String, Object?> before = Map<String, Object?>.from(old! as Map);
    final Map<String, Object?> after = <String, Object?>{};
    for (final String field in before.keys) {
      if (field == 'orders') continue;
      after[field] = result is Map ? result[field] : null;
    }
    if (before['orders'] case final Map<Object?, Object?> orders) {
      final Map<String, List<String>> next = <String, List<String>>{
        for (final MapEntry<Object?, Object?> e in orders.entries)
          '${e.key}': _stringList(e.value),
      };
      final String name = '${result is Map ? result['name'] : ''}';
      final String primary = result is Map
          ? _sectionOf(Map<String, Object?>.from(result), 'position')
          : '';
      // 与路由同顺序模拟：先 position（本分区），再 kanjiPosition（「汉字」分区）。
      for (final (String field, String section) in <(String, String)>[
        ('position', primary),
        ('kanjiPosition', 'kanji'),
      ]) {
        final int? position = call.optInt(field);
        final List<String>? names = next[section];
        if (position == null || names == null) continue;
        names.remove(name);
        names.insert((position - 1).clamp(0, names.length), name);
      }
      after['orders'] = next;
    }
    return after;
  },
);

/// 一本词典在 [key] 列出的字段上的当前值；排序字段换成所在分区的完整名序。
Map<String, Object?> _dictionarySnapshot(
  List<Map<String, Object?>> list,
  Map<String, Object?> key,
) {
  final Map<String, Object?> dict = _resolveDictionary(list, '${key['name']}');
  final Map<String, Object?> out = <String, Object?>{};
  final Map<String, List<String>> orders = <String, List<String>>{};
  for (final String field in _stringList(key['fields'])) {
    if (field == 'position' || field == 'kanjiPosition') {
      final String section = _sectionOf(dict, field);
      // 只留同语言组的名序：路由的 position 是组内位置（D_Nz5R4vSH），撤销时
      // indexOf 得到的必须也是组内下标。
      final String? language = _languageGroupOfJson(dict);
      orders[section] = <String>[
        for (final String name in _sectionNames(list, section))
          if (_languageGroupOfJson(_resolveDictionary(list, name)) == language)
            name,
      ];
    } else {
      out[field] = dict[field];
    }
  }
  if (orders.isNotEmpty) out['orders'] = orders;
  return out;
}

/// 分区内的名序，与词典管理页 / 路由同口径：普通分区按 `order`（`dict.list` 已按
/// 类型、顺序排好），「汉字」分区 = 纯汉字词典 + 带汉字部分的词典，按分区序
/// （`kanjiOrder`，纯汉字词典就是 `order`），同序按列表先后。
List<String> _sectionNames(List<Map<String, Object?>> list, String section) {
  if (section != 'kanji') {
    return <String>[
      for (final Map<String, Object?> d in list)
        if (d['type'] == section) '${d['name']}',
    ];
  }
  final List<(int, int, String)> members = <(int, int, String)>[
    for (int i = 0; i < list.length; i++)
      if (list[i]['type'] == 'kanji' || list[i].containsKey('kanjiEnabled'))
        (
          (list[i]['kanjiOrder'] ?? list[i]['order']) as int? ?? 0,
          i,
          '${list[i]['name']}',
        ),
  ];
  members.sort(((int, int, String) a, (int, int, String) b) {
    final int byOrder = a.$1.compareTo(b.$1);
    return byOrder != 0 ? byOrder : a.$2.compareTo(b.$2);
  });
  return <String>[for (final (int, int, String) m in members) m.$3];
}

/// `dict.list` 一行的语言组，与管理页 / 路由同一判据：`sourceLanguage` 字段就是
/// 词典的有效内容语言（手动指定优先，其次包内声明），经同一规范化。
String? _languageGroupOfJson(Map<String, Object?> dict) {
  final Object? language = dict['sourceLanguage'];
  return canonicalDictionaryLanguageTag(language is String ? language : null);
}

Future<List<Map<String, Object?>>> _listDictionaries(OpDescribeKit kit) async {
  final Object? listed = await kit.callRoute('GET', '/api/admin/dictionaries');
  final Object? rows = listed is Map ? listed['dictionaries'] : null;
  return <Map<String, Object?>>[
    for (final Object? row in rows is List ? rows : const <Object?>[])
      if (row is Map) Map<String, Object?>.from(row),
  ];
}

/// 与路由 `resolveCtlDictionary` 同一套匹配：真名 > 显示名 > 忽略大小写。
Map<String, Object?> _resolveDictionary(
  List<Map<String, Object?>> list,
  String query,
) {
  final String q = query.trim();
  final List<bool Function(Map<String, Object?>)> tiers =
      <bool Function(Map<String, Object?>)>[
        (Map<String, Object?> d) => d['name'] == q,
        (Map<String, Object?> d) => d['displayName'] == q,
        (Map<String, Object?> d) =>
            '${d['name']}'.toLowerCase() == q.toLowerCase() ||
            '${d['displayName']}'.toLowerCase() == q.toLowerCase(),
      ];
  for (final bool Function(Map<String, Object?>) matches in tiers) {
    final List<Map<String, Object?>> hits = list.where(matches).toList();
    if (hits.length == 1) return hits.single;
    if (hits.length > 1) {
      throw CtlFailure.badRequest('「$q」匹配到多本词典，请用真名');
    }
  }
  throw CtlFailure.notFound('没有名为「$q」的词典');
}

Future<void> _deleteDictionary(OpDescribeKit kit, String name) async {
  await kit.callRoute(
    'DELETE',
    '/api/admin/dictionaries/:name',
    params: <String, String>{'name': name},
    body: const <String, Object?>{'confirm': true},
  );
}

// ── dict.install / dict.job.cancel 的撤销 ─────────────────────────────────

/// 安装的撤销：删掉「执行前不在、名字落在这次目标 key 名下」的词典（推荐词典按
/// matchPrefix 认领已装词典，见 `isRecommendedDictionaryInstalled`）。任务还在跑
/// 时报失败（先 dict.job.cancel），不去删半截。
OpUndo _dictionaryInstallUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async => <String, Object?>{
    'before': <String>[
      for (final Map<String, Object?> d in await _listDictionaries(kit))
        '${d['name']}',
    ],
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final List<String> keys = _stringList(
      result is Map ? result['targets'] : null,
    );
    return OpUndoRecord(
      payload: <String, Object?>{...before, 'keys': keys},
      after: keys.join(', '),
    );
  },
  revert: (Map<String, Object?> payload) async {
    try {
      final Object? job = await kit.callRoute(
        'GET',
        '/api/admin/dictionaries/job',
      );
      if (job is Map && job['busy'] == true) {
        return const OpUndoOutcome.failed('词典任务还在进行，先 dict.job.cancel 再撤销');
      }
      final Set<String> before = _stringList(payload['before']).toSet();
      final List<String> keys = _stringList(payload['keys']);
      final List<String> added = <String>[
        for (final Map<String, Object?> d in await _listDictionaries(kit))
          if (!before.contains('${d['name']}') &&
              keys.any((String k) => '${d['name']}'.startsWith(k)))
            '${d['name']}',
      ];
      if (added.isEmpty) {
        return const OpUndoOutcome.superseded('这次安装的词典已不在');
      }
      for (final String name in added) {
        await _deleteDictionary(kit, name);
      }
      return const OpUndoOutcome.done();
    } on CtlFailure catch (failure) {
      return OpUndoOutcome.failed(failure.message ?? failure.code);
    }
  },
);

/// 取消词典任务的撤销 = 按原目标重新发起（已完成的那几本在新任务里会被跳过）。
/// 只有被取消的正是控制通道发起、尚未结束的那个任务时才能重发；app 内发起的任务
/// 不在 `last` 里，撤销报失败。
OpUndo _dictionaryJobCancelUndo(OpDescribeKit kit) => OpUndo(
  capture: (CtlCall call) async {
    final Object? job = await kit.callRoute(
      'GET',
      '/api/admin/dictionaries/job',
    );
    final Object? last = job is Map ? job['last'] : null;
    final bool ours = last is Map && last['finished'] == false;
    return <String, Object?>{
      'restartable': ours,
      if (ours) 'kind': last['kind'],
      if (ours) 'targets': _stringList(last['targets']),
    };
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) =>
      OpUndoRecord(payload: before, after: 'cancelled'),
  revert: (Map<String, Object?> payload) async {
    if (payload['restartable'] != true) {
      return const OpUndoOutcome.failed('被取消的任务不是控制通道发起的，请在词典页重新开始');
    }
    try {
      await kit.callRoute(
        'POST',
        payload['kind'] == 'install'
            ? '/api/admin/dictionaries/install'
            : '/api/admin/dictionaries/update',
        body: <String, Object?>{'names': _stringList(payload['targets'])},
      );
      return const OpUndoOutcome.done();
    } on CtlFailure catch (failure) {
      return OpUndoOutcome.failed(failure.message ?? failure.code);
    }
  },
);

List<String> _stringList(Object? raw) => <String>[
  for (final Object? item in raw is List ? raw : const <Object?>[]) '$item',
];

// ── 通用：带键的快照撤销（同 op_descriptions_games.dart，见回报：候选提进 kit）──

OpUndo _keyedSnapshotUndo({
  required Future<Map<String, Object?>> Function(CtlCall call) keyOf,
  required Future<Object?> Function(Map<String, Object?> key) read,
  required Future<void> Function(Map<String, Object?> key, Object? old) write,
  required Object? Function(CtlCall call, Object? old, Object? result) newValue,
}) => OpUndo(
  capture: (CtlCall call) async {
    final Map<String, Object?> key = await keyOf(call);
    return <String, Object?>{'key': key, 'old': await read(key)};
  },
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Object? after = newValue(call, before['old'], result);
    return OpUndoRecord(
      payload: <String, Object?>{...before, 'new': after},
      before: _display(before['old']),
      after: _display(after),
    );
  },
  revert: (Map<String, Object?> payload) async {
    final Map<String, Object?> key = Map<String, Object?>.from(
      payload['key'] as Map? ?? const <String, Object?>{},
    );
    try {
      if (!OpDescribeKit.sameJson(await read(key), payload['new'])) {
        return const OpUndoOutcome.superseded();
      }
      await write(key, payload['old']);
      return const OpUndoOutcome.done();
    } on CtlFailure catch (failure) {
      return failure.status == 404
          ? OpUndoOutcome.superseded(failure.message)
          : OpUndoOutcome.failed(failure.message ?? failure.code);
    }
  },
);

String? _display(Object? value) {
  if (value == null) return null;
  final String text = value is String ? value : jsonEncode(value);
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}
