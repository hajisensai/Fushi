/// online 域控制通道里「筛选器 / 源偏好」的纯函数：把模型投影成 JSON，把 CLI 传来的
/// 文本取值套回模型。与 UI 的筛选弹窗 / 偏好弹窗写出的形状逐字段一致：
///
/// - Mihon 筛选（`_MihonFilterDialog`）：checkBox → bool、triState → 0/1/2、text →
///   String、select → 下标、sort → `{index, ascending}`、group 只改子项；
/// - LNReader 筛选（`LnReaderFilterDialog`）：走 [LnReaderFilter.withValue]；
/// - Mihon 源偏好（`MihonPreferencesDialog`）：开关 → bool、文本 → String、
///   list → 下标、multiSelect → entryValues 列表。
///
/// 取值约定：选项一律按**显示名或取值**匹配（不区分大小写），`#N` 表示第 N 项
/// （1 起）；布尔接受 true/false/on/off/yes/no/1/0。认不出的取值抛 400 并列出可选项。
library;

import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';

// ── 通用取值解析 ──────────────────────────────────────────────────────────

/// 解析布尔取值；认不出抛 400。
bool parseCtlBool(String raw, String what) {
  switch (raw.trim().toLowerCase()) {
    case 'true' || 'on' || 'yes' || '1' || 'y':
      return true;
    case 'false' || 'off' || 'no' || '0' || 'n':
      return false;
  }
  throw CtlFailure.badRequest('$what 要布尔值（true / false），收到：$raw');
}

/// 在 [labels]（与可选的 [values]）里找 [raw] 对应的下标（0 起）。
///
/// 先按 `#N`（1 起），再按取值精确匹配，最后按显示名（不区分大小写）匹配。
int resolveCtlOptionIndex(
  String raw,
  List<String> labels, {
  List<String> values = const <String>[],
  required String what,
}) {
  // 取值表与显示名表长度不一致时不可信（下标对不上），只按显示名匹配。
  final List<String> trusted = values.length == labels.length
      ? values
      : const <String>[];
  final String text = raw.trim();
  final RegExpMatch? numbered = RegExp(r'^#(\d+)$').firstMatch(text);
  if (numbered != null) {
    final int n = int.parse(numbered.group(1)!);
    if (n >= 1 && n <= labels.length) return n - 1;
    throw CtlFailure.badRequest('$what 只有 ${labels.length} 项：$text');
  }
  final int byValue = trusted.indexOf(text);
  if (byValue >= 0) return byValue;
  final String lower = text.toLowerCase();
  for (int i = 0; i < labels.length; i++) {
    if (labels[i].toLowerCase() == lower) return i;
  }
  for (int i = 0; i < trusted.length; i++) {
    if (trusted[i].toLowerCase() == lower) return i;
  }
  throw CtlFailure.badRequest(
    '$what 没有选项「$text」（可选：${_describeOptions(labels, trusted)}）',
  );
}

String _describeOptions(List<String> labels, List<String> values) => <String>[
  for (int i = 0; i < labels.length; i++)
    values.length == labels.length && values[i] != labels[i]
        ? '#${i + 1} ${labels[i]}=${values[i]}'
        : '#${i + 1} ${labels[i]}',
].join(' / ');

/// 逗号分隔的列表（去空白、去空项）。
List<String> splitCtlList(String raw) => <String>[
  for (final String part in raw.split(','))
    if (part.trim().isNotEmpty) part.trim(),
];

// ── Mihon 筛选 ────────────────────────────────────────────────────────────

/// 某种筛选器能否由 CLI 直接赋值。
bool _mihonFilterSettable(MihonFilter filter) => switch (filter.kind) {
  MihonFilterKind.checkBox ||
  MihonFilterKind.triState ||
  MihonFilterKind.text => true,
  MihonFilterKind.select || MihonFilterKind.sort => filter.values.isNotEmpty,
  MihonFilterKind.header ||
  MihonFilterKind.separator ||
  MihonFilterKind.group ||
  MihonFilterKind.unsupported => false,
};

Map<String, Object?> _mihonFilterJson(MihonFilter filter, String path) =>
    <String, Object?>{
      'path': path,
      'name': filter.name,
      'kind': filter.kind.name,
      'settable': _mihonFilterSettable(filter),
      'state': filter.state,
      if (filter.values.isNotEmpty) 'options': filter.values,
      if (filter.children.isNotEmpty)
        'children': <Map<String, Object?>>[
          for (int j = 0; j < filter.children.length; j++)
            _mihonFilterJson(filter.children[j], '$path.${j + 1}'),
        ],
    };

/// Mihon 筛选器的 JSON（`path` 是 1 起的层级序号，如 `3` / `3.2`）。
List<Map<String, Object?>> ctlMihonFiltersJson(List<MihonFilter> filters) =>
    <Map<String, Object?>>[
      for (int i = 0; i < filters.length; i++)
        _mihonFilterJson(filters[i], '${i + 1}'),
    ];

MihonFilter _mihonWithState(MihonFilter filter, Object? state) => MihonFilter(
  name: filter.name,
  kind: filter.kind,
  state: state,
  values: filter.values,
  children: filter.children,
);

MihonFilter _mihonWithChildren(
  MihonFilter filter,
  List<MihonFilter> children,
) => MihonFilter(
  name: filter.name,
  kind: filter.kind,
  state: filter.state,
  values: filter.values,
  children: children,
);

/// 把一个文本取值换成 [filter] 的状态（形状同筛选弹窗）。
Object? _mihonFilterState(MihonFilter filter, String raw) {
  final String what = '筛选「${filter.name}」';
  switch (filter.kind) {
    case MihonFilterKind.checkBox:
      return parseCtlBool(raw, what);
    case MihonFilterKind.triState:
      switch (raw.trim().toLowerCase()) {
        case 'ignore' || '0' || 'none' || 'off':
          return 0;
        case 'include' || '1' || '+' || 'on':
          return 1;
        case 'exclude' || '2' || '-':
          return 2;
      }
      throw CtlFailure.badRequest('$what 取 ignore / include / exclude：$raw');
    case MihonFilterKind.text:
      return raw;
    case MihonFilterKind.select when filter.values.isNotEmpty:
      return resolveCtlOptionIndex(raw, filter.values, what: what);
    case MihonFilterKind.sort when filter.values.isNotEmpty:
      // `<选项>[:asc|:desc]`；只给 `:desc` 时保留当前排序项。
      final Map<Object?, Object?> current =
          filter.state is Map<Object?, Object?>
          ? filter.state! as Map<Object?, Object?>
          : const <Object?, Object?>{};
      String option = raw.trim();
      bool ascending = current['ascending'] != false;
      final int colon = option.lastIndexOf(':');
      if (colon >= 0) {
        final String direction = option.substring(colon + 1).toLowerCase();
        option = option.substring(0, colon).trim();
        switch (direction) {
          case 'asc' || 'ascending':
            ascending = true;
          case 'desc' || 'descending':
            ascending = false;
          default:
            throw CtlFailure.badRequest('$what 排序方向取 asc / desc：$raw');
        }
      }
      final int index = option.isEmpty
          ? ((current['index'] as num?)?.toInt() ?? 0)
          : resolveCtlOptionIndex(option, filter.values, what: what);
      return <String, Object?>{'index': index, 'ascending': ascending};
    case MihonFilterKind.group:
      throw CtlFailure.badRequest('$what 是分组，改它的子项（如 「${filter.name}/<子项>」）');
    case MihonFilterKind.header ||
        MihonFilterKind.separator ||
        MihonFilterKind.select ||
        MihonFilterKind.sort ||
        MihonFilterKind.unsupported:
      throw CtlFailure.badRequest('$what 不可设置');
  }
}

/// 在 [filters] 里按一段地址（1 起序号或名字）找下标。
int _mihonFilterIndex(List<MihonFilter> filters, String segment, String key) {
  final int? n = int.tryParse(segment);
  if (n != null) {
    if (n >= 1 && n <= filters.length) return n - 1;
    throw CtlFailure.badRequest('筛选 $key 越界（共 ${filters.length} 项）');
  }
  final String lower = segment.trim().toLowerCase();
  final List<int> hits = <int>[
    for (int i = 0; i < filters.length; i++)
      if (filters[i].name.trim().toLowerCase() == lower &&
          filters[i].kind != MihonFilterKind.header &&
          filters[i].kind != MihonFilterKind.separator)
        i,
  ];
  if (hits.isEmpty) {
    throw CtlFailure.badRequest('没有筛选「$key」（先 source filters 看可用项）');
  }
  if (hits.length > 1) {
    throw CtlFailure.badRequest(
      '筛选名「$key」有歧义，改用序号：${hits.map((int i) => i + 1).join(' / ')}',
    );
  }
  return hits.single;
}

MihonFilter _applyMihonPath(
  MihonFilter filter,
  List<String> rest,
  String raw,
  String key,
) {
  if (rest.isEmpty) {
    return _mihonWithState(filter, _mihonFilterState(filter, raw));
  }
  final List<MihonFilter> children = List<MihonFilter>.of(filter.children);
  final int index = _mihonFilterIndex(children, rest.first, key);
  children[index] = _applyMihonPath(children[index], rest.sublist(1), raw, key);
  return _mihonWithChildren(filter, children);
}

/// 把 `{地址: 取值}` 套到源的默认筛选器上（不改动未提到的项）。
///
/// 地址：`3` / `3.2`（序号，见 [ctlMihonFiltersJson] 的 `path`）或 `类型` /
/// `类型/动作`（名字，不区分大小写）。
List<MihonFilter> applyCtlMihonFilters(
  List<MihonFilter> filters,
  Map<String, String> assignments,
) {
  final List<MihonFilter> out = List<MihonFilter>.of(filters);
  for (final MapEntry<String, String> entry in assignments.entries) {
    final String key = entry.key.trim();
    final List<String> segments = key.contains('/')
        ? key.split('/')
        : RegExp(r'^\d+(\.\d+)+$').hasMatch(key)
        ? key.split('.')
        : <String>[key];
    final int index = _mihonFilterIndex(out, segments.first, key);
    out[index] = _applyMihonPath(
      out[index],
      segments.sublist(1),
      entry.value,
      key,
    );
  }
  return out;
}

// ── LNReader 筛选 ─────────────────────────────────────────────────────────

/// LNReader 筛选器的 JSON。
List<Map<String, Object?>> ctlLnReaderFiltersJson(
  List<LnReaderFilter> filters,
) => <Map<String, Object?>>[
  for (final LnReaderFilter filter in filters)
    <String, Object?>{
      'key': filter.key,
      'name': filter.label,
      'kind': filter.type.name,
      'state': filter.value,
      if (filter.options.isNotEmpty)
        'options': <Map<String, String>>[
          for (final LnReaderFilterOption o in filter.options)
            <String, String>{'label': o.label, 'value': o.value},
        ],
    },
];

String _lnReaderOptionValue(LnReaderFilter filter, String raw) {
  final List<String> labels = <String>[
    for (final LnReaderFilterOption o in filter.options) o.label,
  ];
  final List<String> values = <String>[
    for (final LnReaderFilterOption o in filter.options) o.value,
  ];
  return values[resolveCtlOptionIndex(
    raw,
    labels,
    values: values,
    what: '筛选「${filter.label}」',
  )];
}

/// 把 `{key 或显示名: 取值}` 套到插件的筛选器上。
///
/// 取值：text → 原文；picker → 选项；toggle → 布尔；checkbox → 逗号分隔的选项；
/// excludableCheckbox → 逗号分隔、`-` 前缀表示排除（`a,b,-c`）。
List<LnReaderFilter> applyCtlLnReaderFilters(
  List<LnReaderFilter> filters,
  Map<String, String> assignments,
) {
  final List<LnReaderFilter> out = List<LnReaderFilter>.of(filters);
  for (final MapEntry<String, String> entry in assignments.entries) {
    final String key = entry.key.trim();
    int index = out.indexWhere((LnReaderFilter f) => f.key == key);
    if (index < 0) {
      final List<int> hits = <int>[
        for (int i = 0; i < out.length; i++)
          if (out[i].label.toLowerCase() == key.toLowerCase()) i,
      ];
      if (hits.length != 1) {
        throw CtlFailure.badRequest(
          hits.isEmpty
              ? '没有筛选「$key」（先 source filters 看可用项）'
              : '筛选名「$key」有歧义，改用 key',
        );
      }
      index = hits.single;
    }
    final LnReaderFilter filter = out[index];
    final String raw = entry.value;
    final Object value = switch (filter.type) {
      LnReaderFilterType.text => raw,
      LnReaderFilterType.picker =>
        filter.options.isEmpty ? raw : _lnReaderOptionValue(filter, raw),
      LnReaderFilterType.toggle => parseCtlBool(raw, '筛选「${filter.label}」'),
      LnReaderFilterType.checkbox => <String>[
        for (final String item in splitCtlList(raw))
          _lnReaderOptionValue(filter, item),
      ],
      LnReaderFilterType.excludableCheckbox => <String, List<String>>{
        'include': <String>[
          for (final String item in splitCtlList(raw))
            if (!item.startsWith('-'))
              _lnReaderOptionValue(
                filter,
                item.startsWith('+') ? item.substring(1) : item,
              ),
        ],
        'exclude': <String>[
          for (final String item in splitCtlList(raw))
            if (item.startsWith('-'))
              _lnReaderOptionValue(filter, item.substring(1)),
        ],
      },
    };
    out[index] = filter.withValue(value);
  }
  return out;
}

// ── Mihon 源偏好 ──────────────────────────────────────────────────────────

/// 源偏好的 JSON（list 额外给 `valueLabel`）。
List<Map<String, Object?>> ctlMihonPreferencesJson(
  List<MihonPreference> preferences,
) => <Map<String, Object?>>[
  for (final MihonPreference p in preferences)
    <String, Object?>{
      'key': p.key,
      'kind': p.kind.name,
      'title': p.title,
      if (p.summary.isNotEmpty) 'summary': p.summary,
      'value': p.value,
      if (p.kind == MihonPreferenceKind.list &&
          p.value is int &&
          (p.value! as int) >= 0 &&
          (p.value! as int) < p.entries.length)
        'valueLabel': p.entries[p.value! as int],
      if (p.entries.isNotEmpty) 'entries': p.entries,
      if (p.entryValues.isNotEmpty) 'entryValues': p.entryValues,
    },
];

/// 按 key 找偏好；没有抛 404。
MihonPreference findCtlMihonPreference(
  List<MihonPreference> preferences,
  String key,
) {
  for (final MihonPreference p in preferences) {
    if (p.key == key) return p;
  }
  throw CtlFailure.notFound(
    '没有偏好 $key（可用：${preferences.map((MihonPreference p) => p.key).join(' / ')}）',
  );
}

/// 用文本取值造一条改过的偏好（与偏好弹窗 `_persistPreference` 同形）。
MihonPreference ctlMihonPreferenceWithValue(
  MihonPreference preference,
  String raw,
) {
  final String what = '偏好「${preference.title}」';
  final Object value = switch (preference.kind) {
    MihonPreferenceKind.checkBox ||
    MihonPreferenceKind.switchControl => parseCtlBool(raw, what),
    MihonPreferenceKind.text => raw,
    MihonPreferenceKind.list => resolveCtlOptionIndex(
      raw,
      preference.entries,
      values: preference.entryValues,
      what: what,
    ),
    MihonPreferenceKind.multiSelect => <String>[
      for (final String item in splitCtlList(raw))
        preference.entryValues[resolveCtlOptionIndex(
          item,
          preference.entries,
          values: preference.entryValues,
          what: what,
        )],
    ],
    MihonPreferenceKind.unsupported => throw CtlFailure.rejected(
      '$what 的类型宿主不支持，无法设置',
    ),
  };
  return MihonPreference(
    key: preference.key,
    kind: preference.kind,
    title: preference.title,
    summary: preference.summary,
    value: value,
    entries: preference.entries,
    entryValues: preference.entryValues,
  );
}
