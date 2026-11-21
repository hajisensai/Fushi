/// 「导入文本文件」（CSV / TSV / TXT）的选项对话框，对齐 Anki「导入 → 文本文件」页：
///
/// - 文件：字段分隔符、字段允许 HTML（改了就按新设置重解析，列映射跟着变）；
/// - 笔记类型与牌组；
/// - 字段映射：笔记类型的每个字段取哪一列（选项带第一行的样例），标签列；文件头声明了牌组列 / GUID 列时
///   也可改；
/// - 已存在的笔记：更新 / 保留现有 / 两者都保留，匹配范围（笔记类型 / 笔记类型和牌组）；附加标签。
///
/// 初值来自文件头（`#notetype:` / `#deck:` / `#if matches:` / `#match scope:` / `#tags:` / `… column:`）。
/// 解析在原生内核（[parseSrsTextFile]），这里只拿预览（前几行）与列数。
library;

import 'package:fushi_engine/srs/text/srs_text_import.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 预览取的行数（列选项的样例取第一行）。
const int kSrsTextImportPreviewRows = 5;

/// 对话框选完的结果：全文按 [delimiter] / [html] 再解析一遍后按 [options] 导入。
class SrsTextImportChoice {
  const SrsTextImportChoice({
    required this.delimiter,
    required this.html,
    required this.options,
  });

  final String delimiter;
  final bool html;
  final SrsTextImportOptions options;
}

/// 按新的分隔符 / HTML 设置重解析预览。
typedef SrsTextReparse =
    Future<SrsTextFile> Function(String delimiter, bool html);

/// 可选的分隔符（Anki 的六种，与原生内核猜测的顺序相同）。
const List<String> kSrsTextDelimiters = <String>['\t', '|', ';', ':', ',', ' '];

String _delimiterLabel(String d) => switch (d) {
  '\t' => t.srs_text_import_delim_tab,
  '|' => t.srs_text_import_delim_pipe,
  ';' => t.srs_text_import_delim_semicolon,
  ':' => t.srs_text_import_delim_colon,
  ',' => t.srs_text_import_delim_comma,
  ' ' => t.srs_text_import_delim_space,
  _ => d,
};

/// 弹出对话框；取消返回 null。[preview] 是按文件头 / 猜测解析出的前几行。
Future<SrsTextImportChoice?> showSrsTextImportDialog({
  required BuildContext context,
  required String fileName,
  required SrsTextFile preview,
  required List<SrsNoteTypeView> noteTypes,
  required SrsDeckTree decks,
  required String defaultDeckId,
  required SrsTextReparse reparse,
}) => showAppDialog<SrsTextImportChoice>(
  context: context,
  builder: (BuildContext dialogContext) => SrsTextImportDialog(
    fileName: fileName,
    preview: preview,
    noteTypes: noteTypes,
    decks: decks,
    defaultDeckId: defaultDeckId,
    reparse: reparse,
  ),
);

class SrsTextImportDialog extends StatefulWidget {
  const SrsTextImportDialog({
    required this.fileName,
    required this.preview,
    required this.noteTypes,
    required this.decks,
    required this.defaultDeckId,
    required this.reparse,
    super.key,
  });

  final String fileName;
  final SrsTextFile preview;
  final List<SrsNoteTypeView> noteTypes;
  final SrsDeckTree decks;
  final String defaultDeckId;
  final SrsTextReparse reparse;

  /// 正文宽度（与「导入选项」对话框同档）。
  static const double contentWidth = 520;

  @override
  State<SrsTextImportDialog> createState() => _SrsTextImportDialogState();
}

class _SrsTextImportDialogState extends State<SrsTextImportDialog> {
  late SrsTextFile _file = widget.preview;
  late String _delimiter = widget.preview.delimiter;
  late bool _html = widget.preview.html;
  late SrsNoteTypeView? _type = _initialType();
  late String _deckId = _initialDeck();
  late List<int> _fieldColumns = _defaultColumns();
  late int _tagsColumn = widget.preview.tagsColumn ?? 0;
  late int _deckColumn = widget.preview.deckColumn ?? 0;
  late int _guidColumn = widget.preview.guidColumn ?? 0;
  late SrsTextDupeMode _dupeMode =
      widget.preview.ifMatches ?? SrsTextDupeMode.update;
  late SrsTextMatchScope _matchScope =
      widget.preview.matchScope ?? SrsTextMatchScope.noteType;
  late final TextEditingController _tags = TextEditingController(
    text: widget.preview.tags.join(' '),
  );
  bool _reparsing = false;
  Object? _reparseError;

  @override
  void dispose() {
    _tags.dispose();
    super.dispose();
  }

  SrsNoteTypeView? _initialType() {
    final String? want = widget.preview.noteType?.trim().toLowerCase();
    if (want != null && want.isNotEmpty) {
      for (final SrsNoteTypeView nt in widget.noteTypes) {
        if (nt.name.toLowerCase() == want) return nt;
      }
    }
    return widget.noteTypes.firstOrNull;
  }

  String _initialDeck() {
    final String? want = widget.preview.deck?.trim().toLowerCase();
    if (want != null && want.isNotEmpty) {
      for (final SrsDeckView d in widget.decks.decks) {
        if (widget.decks.fullName(d.id).toLowerCase() == want) return d.id;
      }
    }
    return widget.defaultDeckId;
  }

  List<int> _defaultColumns() => _type == null
      ? const <int>[]
      : srsTextDefaultFieldColumns(<String>[
          for (final SrsFieldDef f in _type!.fields) f.name,
        ], _file);

  Future<void> _reparse({String? delimiter, bool? html}) async {
    final String d = delimiter ?? _delimiter;
    final bool h = html ?? _html;
    setState(() {
      _delimiter = d;
      _html = h;
      _reparsing = true;
    });
    try {
      final SrsTextFile f = await widget.reparse(d, h);
      if (!mounted) return;
      setState(() {
        final bool sameShape = f.columnCount == _file.columnCount;
        _file = f;
        _reparseError = null;
        if (!sameShape) _fieldColumns = _defaultColumns();
      });
    } catch (e) {
      if (mounted) setState(() => _reparseError = e);
    } finally {
      if (mounted) setState(() => _reparsing = false);
    }
  }

  /// 列选项：「不导入」+ 每一列（带第一行的样例）。
  List<AdaptiveSettingsPickerOption<int>> get _columnOptions {
    final List<String> sample = _file.rows.firstOrNull ?? const <String>[];
    String label(int col) {
      final String name = col <= _file.columns.length
          ? _file.columns[col - 1].trim()
          : '';
      String example = col <= sample.length ? sample[col - 1] : '';
      example = example.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
      if (example.length > 24) example = '${example.substring(0, 24)}…';
      final String head = t.srs_text_import_column(n: col);
      final String detail = name.isNotEmpty ? name : example;
      return detail.isEmpty ? head : '$head · $detail';
    }

    return <AdaptiveSettingsPickerOption<int>>[
      AdaptiveSettingsPickerOption<int>(
        value: 0,
        label: t.srs_text_import_column_none,
      ),
      for (int c = 1; c <= _file.columnCount; c++)
        AdaptiveSettingsPickerOption<int>(value: c, label: label(c)),
    ];
  }

  int _clampColumn(int c) => c > _file.columnCount ? 0 : c;

  void _confirm() {
    final SrsNoteTypeView? type = _type;
    if (type == null) return;
    Navigator.of(context).pop(
      SrsTextImportChoice(
        delimiter: _delimiter,
        html: _html,
        options: SrsTextImportOptions(
          noteTypeId: type.id,
          deckId: _deckId,
          fieldColumns: <int>[
            for (int i = 0; i < type.fields.length; i++)
              i < _fieldColumns.length ? _clampColumn(_fieldColumns[i]) : 0,
          ],
          tagsColumn: _clampColumn(_tagsColumn) == 0 ? null : _tagsColumn,
          deckColumn: _clampColumn(_deckColumn) == 0 ? null : _deckColumn,
          guidColumn: _clampColumn(_guidColumn) == 0 ? null : _guidColumn,
          tags: _tags.text
              .split(RegExp(r'\s+'))
              .where((String s) => s.isNotEmpty)
              .toList(),
          dupeMode: _dupeMode,
          matchScope: _matchScope,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool narrow = MediaQuery.sizeOf(context).width < 600;
    final Size screen = MediaQuery.sizeOf(context);
    final double insetX = (screen.width * 0.05).clamp(16.0, 40.0);
    final SrsNoteTypeView? type = _type;
    final List<AdaptiveSettingsPickerOption<int>> columns = _columnOptions;
    int step = 0;
    Widget stagger(Widget child) => Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: FushiStaggeredEntrance(index: step++, child: child),
    );
    final List<String> deckIds =
        widget.decks.decks.map((SrsDeckView d) => d.id).toList()..sort(
          (String a, String b) =>
              widget.decks.fullName(a).compareTo(widget.decks.fullName(b)),
        );

    return FushiAlertDialog(
      insetPadding: EdgeInsets.symmetric(horizontal: insetX, vertical: 24),
      scrollable: true,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(t.srs_text_import_title),
          const SizedBox(height: 2),
          Text(
            '${widget.fileName} · ${t.srs_text_import_rows(n: _file.total)}',
            key: const ValueKey<String>('srs-text-import-file'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: SrsTextImportDialog.contentWidth,
        child: FushiEntranceScope(
          child: Column(
            key: const ValueKey<String>('srs-text-import-options'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_reparseError != null)
                stagger(
                  FushiInlineNotice(
                    message: t.srs_text_import_failed(error: '$_reparseError'),
                  ),
                )
              else if (_file.total == 0)
                stagger(FushiInlineNotice(message: t.srs_text_import_empty)),
              stagger(
                AdaptiveSettingsSection(
                  children: <Widget>[
                    AdaptiveSettingsPickerRow<String>(
                      key: const ValueKey<String>('srs-text-import-delimiter'),
                      title: t.srs_text_import_delimiter,
                      options: <AdaptiveSettingsPickerOption<String>>[
                        for (final String d in kSrsTextDelimiters)
                          AdaptiveSettingsPickerOption<String>(
                            value: d,
                            label: _delimiterLabel(d),
                          ),
                      ],
                      selected: _delimiter,
                      materialWidth: 180,
                      controlBelow: narrow,
                      onChanged: (String d) {
                        if (!_reparsing && d != _delimiter) {
                          _reparse(delimiter: d);
                        }
                      },
                    ),
                    AdaptiveSettingsSwitchRow(
                      key: const ValueKey<String>('srs-text-import-html'),
                      title: t.srs_text_import_html,
                      value: _html,
                      onChanged: (bool v) {
                        if (!_reparsing) _reparse(html: v);
                      },
                    ),
                  ],
                ),
              ),
              stagger(
                AdaptiveSettingsSection(
                  children: <Widget>[
                    AdaptiveSettingsPickerRow<String>(
                      key: const ValueKey<String>('srs-text-import-note-type'),
                      title: t.srs_text_import_note_type,
                      options: <AdaptiveSettingsPickerOption<String>>[
                        for (final SrsNoteTypeView nt in widget.noteTypes)
                          AdaptiveSettingsPickerOption<String>(
                            value: nt.id,
                            label: nt.name,
                          ),
                      ],
                      selected: type?.id ?? '',
                      materialWidth: 220,
                      controlBelow: narrow,
                      onChanged: (String id) => setState(() {
                        _type = widget.noteTypes.firstWhere(
                          (SrsNoteTypeView nt) => nt.id == id,
                        );
                        _fieldColumns = _defaultColumns();
                      }),
                    ),
                    AdaptiveSettingsPickerRow<String>(
                      key: const ValueKey<String>('srs-text-import-deck'),
                      title: t.srs_text_import_deck,
                      options: <AdaptiveSettingsPickerOption<String>>[
                        for (final String id in deckIds)
                          AdaptiveSettingsPickerOption<String>(
                            value: id,
                            label: widget.decks.fullName(id),
                          ),
                      ],
                      selected: _deckId,
                      materialWidth: 220,
                      controlBelow: narrow,
                      onChanged: (String id) => setState(() => _deckId = id),
                    ),
                  ],
                ),
              ),
              if (type != null)
                stagger(
                  AdaptiveSettingsSection(
                    title: t.srs_text_import_section_fields,
                    titlePlacement: SettingsSectionTitlePlacement.inside,
                    children: <Widget>[
                      for (int i = 0; i < type.fields.length; i++)
                        AdaptiveSettingsPickerRow<int>(
                          key: ValueKey<String>('srs-text-import-field-$i'),
                          title: type.fields[i].name,
                          options: columns,
                          selected: _clampColumn(
                            i < _fieldColumns.length ? _fieldColumns[i] : 0,
                          ),
                          materialWidth: 220,
                          controlBelow: narrow,
                          onChanged: (int c) => setState(() {
                            _fieldColumns = <int>[
                              for (int k = 0; k < type.fields.length; k++)
                                k == i
                                    ? c
                                    : (k < _fieldColumns.length
                                          ? _fieldColumns[k]
                                          : 0),
                            ];
                          }),
                        ),
                      AdaptiveSettingsPickerRow<int>(
                        key: const ValueKey<String>(
                          'srs-text-import-tags-column',
                        ),
                        title: t.srs_text_import_tags_column,
                        subtitle: t.srs_text_import_tags_column_hint,
                        options: columns,
                        selected: _clampColumn(_tagsColumn),
                        materialWidth: 220,
                        controlBelow: narrow,
                        onChanged: (int c) => setState(() => _tagsColumn = c),
                      ),
                      if (widget.preview.deckColumn != null)
                        AdaptiveSettingsPickerRow<int>(
                          key: const ValueKey<String>(
                            'srs-text-import-deck-column',
                          ),
                          title: t.srs_text_import_deck_column,
                          options: columns,
                          selected: _clampColumn(_deckColumn),
                          materialWidth: 220,
                          controlBelow: narrow,
                          onChanged: (int c) => setState(() => _deckColumn = c),
                        ),
                      if (widget.preview.guidColumn != null)
                        AdaptiveSettingsPickerRow<int>(
                          key: const ValueKey<String>(
                            'srs-text-import-guid-column',
                          ),
                          title: t.srs_text_import_guid_column,
                          options: columns,
                          selected: _clampColumn(_guidColumn),
                          materialWidth: 220,
                          controlBelow: narrow,
                          onChanged: (int c) => setState(() => _guidColumn = c),
                        ),
                    ],
                  ),
                ),
              stagger(
                AdaptiveSettingsSection(
                  children: <Widget>[
                    AdaptiveSettingsPickerRow<SrsTextDupeMode>(
                      key: const ValueKey<String>('srs-text-import-existing'),
                      title: t.srs_text_import_existing,
                      options: <AdaptiveSettingsPickerOption<SrsTextDupeMode>>[
                        AdaptiveSettingsPickerOption<SrsTextDupeMode>(
                          value: SrsTextDupeMode.update,
                          label: t.srs_text_import_existing_update,
                        ),
                        AdaptiveSettingsPickerOption<SrsTextDupeMode>(
                          value: SrsTextDupeMode.preserve,
                          label: t.srs_text_import_existing_preserve,
                        ),
                        AdaptiveSettingsPickerOption<SrsTextDupeMode>(
                          value: SrsTextDupeMode.duplicate,
                          label: t.srs_text_import_existing_duplicate,
                        ),
                      ],
                      selected: _dupeMode,
                      materialWidth: 180,
                      controlBelow: narrow,
                      onChanged: (SrsTextDupeMode m) =>
                          setState(() => _dupeMode = m),
                    ),
                    AdaptiveSettingsPickerRow<SrsTextMatchScope>(
                      key: const ValueKey<String>('srs-text-import-scope'),
                      title: t.srs_text_import_match_scope,
                      options:
                          <AdaptiveSettingsPickerOption<SrsTextMatchScope>>[
                            AdaptiveSettingsPickerOption<SrsTextMatchScope>(
                              value: SrsTextMatchScope.noteType,
                              label: t.srs_text_import_match_note_type,
                            ),
                            AdaptiveSettingsPickerOption<SrsTextMatchScope>(
                              value: SrsTextMatchScope.noteTypeAndDeck,
                              label: t.srs_text_import_match_note_type_deck,
                            ),
                          ],
                      selected: _matchScope,
                      materialWidth: 180,
                      controlBelow: narrow,
                      onChanged: (SrsTextMatchScope s) =>
                          setState(() => _matchScope = s),
                    ),
                    AdaptiveSettingsRow(
                      title: t.srs_text_import_tags,
                      controlBelow: true,
                      trailing: AdaptiveSettingsTextField(
                        key: const ValueKey<String>('srs-text-import-tags'),
                        controller: _tags,
                        hintText: t.srs_text_import_tags_hint,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs-text-import-confirm'),
          label: t.srs_import,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed:
              type == null ||
                  _reparsing ||
                  _reparseError != null ||
                  _file.total == 0
              ? null
              : _confirm,
        ),
      ],
    );
  }
}
