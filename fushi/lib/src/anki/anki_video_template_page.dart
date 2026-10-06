import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

import 'package:fushi/src/anki/anki_video_template_service.dart';

/// Explicitly opt in to modifying the selected note type, with reversible backup.
class AnkiVideoTemplatePage extends StatefulWidget {
  const AnkiVideoTemplatePage({
    required this.service,
    required this.modelName,
    this.initialFieldMappings = const <String, String>{},
    this.onApplied,
    this.previewBuilder,
    super.key,
  });

  final AnkiVideoTemplateService service;
  final String modelName;
  final Map<String, String> initialFieldMappings;
  final Future<void> Function()? onApplied;
  @visibleForTesting
  final Widget Function(BuildContext, String)? previewBuilder;

  @override
  State<AnkiVideoTemplatePage> createState() => _AnkiVideoTemplatePageState();
}

class _AnkiVideoTemplatePageState extends State<AnkiVideoTemplatePage> {
  AnkiNoteTypeDefinition? _definition;
  String? _field;
  AnkiVideoPlacement _placement = AnkiVideoPlacement.bottom;
  bool _autoplay = true;
  bool _busy = true;
  String? _error;
  String? _notice;
  String? _preview;
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'anki-video-template-preview',
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  bool _eligible(String field) {
    final String mapping = (widget.initialFieldMappings[field] ?? '').trim();
    return mapping.isEmpty ||
        mapping == '{card-video}' ||
        AnkiHandlebarOptions.cardImageTokens.contains(mapping);
  }

  Future<void> _load() async {
    try {
      final AnkiNoteTypeDefinition? definition = await widget.service.read(
        widget.modelName,
      );
      if (!mounted) return;
      final AnkiVideoTemplateOptions? saved = definition == null
          ? null
          : readAnkiVideoTemplateOptions(definition);
      String? field = saved?.field;
      field ??= widget.initialFieldMappings.entries
          .where(
            (MapEntry<String, String> entry) =>
                entry.value.trim() == '{card-video}' &&
                (definition?.fields.contains(entry.key) ?? false),
          )
          .map((MapEntry<String, String> entry) => entry.key)
          .firstOrNull;
      if (field == null && definition != null) {
        for (final String candidate in definition.fields) {
          if (AnkiHandlebarOptions.cardImageTokens.any(
            (String token) =>
                (widget.initialFieldMappings[candidate] ?? '').contains(token),
          )) {
            field = candidate;
            break;
          }
        }
        field ??= definition.fields.contains('Picture')
            ? 'Picture'
            : definition.fields.firstOrNull;
      }
      setState(() {
        _definition = definition;
        _field = field;
        _placement = saved?.placement ?? AnkiVideoPlacement.bottom;
        _autoplay = saved?.autoplay ?? true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  AnkiVideoTemplateOptions get _options => AnkiVideoTemplateOptions(
    field: _field!,
    placement: _placement,
    autoplay: _autoplay,
  );

  Future<void> _write({required bool restore}) async {
    final AnkiNoteTypeDefinition? expected = _definition;
    if (_busy || expected == null || _field == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _preview = null;
    });
    try {
      if (restore) {
        await widget.service.restore(expected: expected);
      } else {
        await widget.service.apply(expected: expected, options: _options);
      }
      await widget.onApplied?.call();
      if (!mounted) return;
      setState(
        () => _notice = restore
            ? t.anki_video_template_restored
            : t.anki_video_template_applied,
      );
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  void _showPreview() {
    try {
      final AnkiNoteTypeDefinition patched = applyAnkiVideoTemplate(
        _definition!,
        _options,
      );
      setState(() {
        _preview = buildAnkiVideoTemplatePreview(patched, _options);
        _error = null;
      });
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AnkiNoteTypeDefinition? definition = _definition;
    final int audioTokenCount = widget.initialFieldMappings.entries
        .where(
          (MapEntry<String, String> entry) =>
              entry.key != _field &&
              (definition?.fields.contains(entry.key) ?? false),
        )
        .fold<int>(
          0,
          (int count, MapEntry<String, String> entry) =>
              count +
              RegExp(r'\{sentence-audio\}').allMatches(entry.value).length,
        );
    final bool hasAudio = audioTokenCount == 1;
    final bool available =
        definition != null &&
        definition.fields.isNotEmpty &&
        definition.templates.isNotEmpty;
    return FushiToolScaffold(
      title: t.anki_video_template_title,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              Text(
                widget.modelName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Text(t.anki_video_template_scope_hint),
              const SizedBox(height: 12),
              Text(t.anki_video_template_format_hint),
              const SizedBox(height: 12),
              Text(t.anki_video_template_media_hint),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_notice!),
                ),
              if (!_busy && !available) ...<Widget>[
                const SizedBox(height: 16),
                Text(t.anki_video_template_unsupported),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _busy = true;
                      _error = null;
                    });
                    unawaited(_load());
                  },
                  child: Text(t.anki_video_template_reload),
                ),
              ],
              if (available) ...<Widget>[
                const SizedBox(height: 24),
                DropdownButtonFormField<String>(
                  key: ValueKey<String>('field-$_field'),
                  initialValue: _field,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t.anki_video_template_field,
                  ),
                  items: definition.fields
                      .map(
                        (String field) => DropdownMenuItem<String>(
                          value: field,
                          enabled: _eligible(field),
                          child: Text(field),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (String? value) => setState(() {
                          _field = value;
                          _preview = null;
                        }),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<AnkiVideoPlacement>(
                  key: ValueKey<AnkiVideoPlacement>(_placement),
                  initialValue: _placement,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t.anki_video_template_placement,
                  ),
                  items: <DropdownMenuItem<AnkiVideoPlacement>>[
                    DropdownMenuItem(
                      value: AnkiVideoPlacement.picture,
                      child: Text(t.anki_video_template_picture),
                    ),
                    DropdownMenuItem(
                      value: AnkiVideoPlacement.bottom,
                      child: Text(t.anki_video_template_bottom),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (AnkiVideoPlacement? value) => setState(() {
                          _placement = value!;
                          _preview = null;
                        }),
                ),
                const SizedBox(height: 8),
                Text(t.anki_video_template_placement_hint),
                AdaptiveSettingsSwitchRow(
                  horizontalPadding: 0,
                  title: t.anki_video_template_autoplay,
                  value: _autoplay,
                  onChanged: _busy
                      ? null
                      : (bool value) => setState(() {
                          _autoplay = value;
                          _preview = null;
                        }),
                ),
                if (!hasAudio)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(t.anki_video_template_audio_required),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: _busy || _field == null ? null : _showPreview,
                      child: Text(t.anki_video_template_preview),
                    ),
                    FilledButton(
                      onPressed: _busy || _field == null || !hasAudio
                          ? null
                          : () => unawaited(_write(restore: false)),
                      child: Text(t.anki_video_template_apply),
                    ),
                    TextButton(
                      onPressed:
                          _busy ||
                              readAnkiVideoTemplateRecoveryOptions(
                                    definition,
                                  ) ==
                                  null
                          ? null
                          : () => unawaited(_write(restore: true)),
                      child: Text(t.anki_video_template_restore),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(t.anki_video_template_restore_hint),
                if (_preview != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(t.anki_video_template_preview_hint),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 360,
                    child:
                        widget.previewBuilder?.call(context, _preview!) ??
                        KeyedSubtree(
                          key: ValueKey<String>(
                            '${_deathGuard.epoch}-$_preview',
                          ),
                          child: InAppWebView(
                            initialData: InAppWebViewInitialData(
                              data: _preview!,
                              mimeType: 'text/html',
                              encoding: 'utf-8',
                            ),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: false,
                              supportZoom: false,
                              disableContextMenu: true,
                            ),
                            onWebContentProcessDidTerminate: (_) => unawaited(
                              _deathGuard.handleWebContentTerminated(),
                            ),
                            onRenderProcessGone:
                                (_, RenderProcessGoneDetail detail) =>
                                    unawaited(
                                      _deathGuard.handleDeath(
                                        didCrash: detail.didCrash,
                                        rendererPriorityAtExit:
                                            detail.rendererPriorityAtExit,
                                      ),
                                    ),
                          ),
                        ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Static layout only: no template scripts, collection resources or media loaded.
/// Render the actual patched back with sample field values, never write samples.
@visibleForTesting
String buildAnkiVideoTemplatePreview(
  AnkiNoteTypeDefinition definition,
  AnkiVideoTemplateOptions options,
) {
  if (definition.templates.isEmpty) {
    throw ArgumentError.value(
      definition.templates,
      'templates',
      'No card back to preview',
    );
  }
  const HtmlEscape escape = HtmlEscape();
  final String template = definition.templates.first.back;
  final Map<String, String> samples = <String, String>{
    for (final String field in definition.fields) field: escape.convert(field),
    options.field: '<span data-fushi-preview-source="true"></span>',
  };
  final dom.DocumentFragment fragment = html.parseFragment(
    renderAnkiTemplate(template, samples),
  );
  for (final dom.Element script in fragment.querySelectorAll('script')) {
    script.remove();
  }
  final List<dom.Element> markers = fragment.querySelectorAll(
    '[data-fushi-preview-source]',
  );
  final dom.Element? pictureAnchor = markers
      .where(_staticPreviewAnchor)
      .firstOrNull;
  final dom.Element sample = dom.Element.tag('div')
    ..attributes['data-fushi-preview-video'] = options.placement.name
    ..attributes['style'] =
        'padding:32px;background:#203040;color:white;text-align:center'
    ..text = '▶ ${options.field}';
  if (options.placement == AnkiVideoPlacement.picture &&
      pictureAnchor != null) {
    pictureAnchor.replaceWith(sample);
  } else {
    // JS mounts this host at the bottom unless a visible picture anchor exists.
    // Simulate that placement explicitly; never leave the sample at the old field.
    final dom.Element? host = fragment.querySelector('#fushi-video-player');
    if (host != null) {
      host.nodes.add(sample);
    } else {
      fragment.nodes.add(sample);
    }
  }
  for (final dom.Element marker in markers) {
    marker.remove();
  }
  final String rendered = fragment.outerHtml;
  return '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:"><style>${definition.css}</style></head><body class="card">$rendered</body></html>''';
}

/// Template content and explicitly hidden containers are not static anchors.
/// Collection scripts and stylesheet-driven visibility still need a real card.
bool _staticPreviewAnchor(dom.Element marker) {
  dom.Element? current = marker;
  while (current != null) {
    final String style = (current.attributes['style'] ?? '')
        .replaceAll(RegExp(r'\s'), '')
        .toLowerCase();
    if (current.localName == 'template' ||
        current.attributes.containsKey('hidden') ||
        current.classes.contains('picture-field-background') ||
        style.contains('display:none') ||
        style.contains('visibility:hidden')) {
      return false;
    }
    current = current.parent;
  }
  return true;
}
