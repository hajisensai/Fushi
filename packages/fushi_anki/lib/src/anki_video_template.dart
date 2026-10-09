import 'dart:convert';

import 'anki_note_type_definition.dart';

enum AnkiVideoPlacement { picture, bottom }

/// Settings for the reversible, back-side managed video player.
class AnkiVideoTemplateOptions {
  const AnkiVideoTemplateOptions({
    required this.field,
    this.placement = AnkiVideoPlacement.bottom,
    this.autoplay = true,
    this.previousFields = const <String>[],
  });
  final String field;
  final AnkiVideoPlacement placement;
  final bool autoplay;

  /// Older video fields, newest first. Used when the current field has no media.
  /// Entries must be unique, exist on the note type, and exclude [field].
  final List<String> previousFields;
  Map<String, dynamic> toJson() => <String, dynamic>{
    'field': field,
    'placement': placement.name,
    'autoplay': autoplay,
    'previousFields': previousFields,
  };
  factory AnkiVideoTemplateOptions.fromJson(
    Map<String, dynamic> json,
  ) => AnkiVideoTemplateOptions(
    field: json['field'] as String,
    placement: AnkiVideoPlacement.values.byName(json['placement'] as String),
    autoplay: json['autoplay'] as bool,
    previousFields:
        (json['previousFields'] as List?)?.cast<String>() ?? const <String>[],
  );
}

const String _start = '<!-- fushi-video:v1:';
const String _end = '<!-- /fushi-video:v1 -->';
final RegExp _block = RegExp(
  r'<!-- fushi-video:v1:([A-Za-z0-9+/=]+) -->.*?<!-- /fushi-video:v1 -->',
  dotAll: true,
);

AnkiNoteTypeDefinition _withBacks(
  AnkiNoteTypeDefinition definition,
  String Function(String) transform,
) => AnkiNoteTypeDefinition(
  name: definition.name,
  fields: definition.fields,
  css: definition.css,
  templates: <AnkiCardTemplate>[
    for (final AnkiCardTemplate card in definition.templates)
      AnkiCardTemplate(
        name: card.name,
        front: card.front,
        back: transform(card.back),
      ),
  ],
);

/// Removes only complete managed blocks; the original template is unchanged.
AnkiNoteTypeDefinition removeAnkiVideoTemplate(
  AnkiNoteTypeDefinition definition,
) => _withBacks(definition, (String back) {
  final String remainder = back.replaceAll(_block, '');
  if (_hasManagedMarker(remainder) ||
      _block
          .allMatches(back)
          .any(
            (RegExpMatch match) =>
                match.group(0)!.indexOf(_start, _start.length) != -1,
          )) {
    throw StateError(
      'The Fushi video marker is incomplete or unsupported. Restore the template backup before removing video adaptation.',
    );
  }
  return remainder;
});

bool _hasManagedMarker(String html) =>
    html.contains('<!-- fushi-video:') || html.contains('<!-- /fushi-video:');

/// Installs the same player on each back without replacing user markup.
AnkiNoteTypeDefinition applyAnkiVideoTemplate(
  AnkiNoteTypeDefinition definition,
  AnkiVideoTemplateOptions options,
) {
  if (!_validFields(definition, options)) {
    throw ArgumentError.value(
      options.field,
      'field',
      'Choose an existing plain field name',
    );
  }
  if (definition.templates.any(
        (AnkiCardTemplate card) => _hasManagedMarker(card.back),
      ) &&
      readAnkiVideoTemplateOptions(definition) == null) {
    throw StateError(
      'The Fushi video block has been edited. Restore video adaptation before applying new settings.',
    );
  }
  final AnkiNoteTypeDefinition clean = removeAnkiVideoTemplate(definition);
  if (clean.templates.any(
    (AnkiCardTemplate card) =>
        card.back.contains(_start) || card.back.contains(_end),
  )) {
    throw StateError(
      'A damaged Fushi video block must be restored before updating',
    );
  }
  return _withBacks(clean, (String back) => back + _managedBlock(options));
}

/// Fail closed if any card is missing, edited, or has inconsistent settings.
AnkiVideoTemplateOptions? readAnkiVideoTemplateOptions(
  AnkiNoteTypeDefinition definition,
) => _readOptions(definition, requireIntactPlayer: true);

/// Recovery-only metadata: accepts edits inside a complete known-version block.
/// This does not establish playback capability and must not enable mining.
AnkiVideoTemplateOptions? readAnkiVideoTemplateRecoveryOptions(
  AnkiNoteTypeDefinition definition,
) => _readOptions(definition, requireIntactPlayer: false);

AnkiVideoTemplateOptions? _readOptions(
  AnkiNoteTypeDefinition definition, {
  required bool requireIntactPlayer,
}) {
  if (definition.templates.isEmpty) return null;
  AnkiVideoTemplateOptions? result;
  for (final AnkiCardTemplate card in definition.templates) {
    final List<RegExpMatch> matches = _block.allMatches(card.back).toList();
    if (matches.length != 1) return null;
    final String unmanaged = card.back.replaceAll(_block, '');
    if (_hasManagedMarker(unmanaged) ||
        matches.single.group(0)!.indexOf(_start, _start.length) != -1)
      return null;
    try {
      final AnkiVideoTemplateOptions options =
          AnkiVideoTemplateOptions.fromJson(
            jsonDecode(utf8.decode(base64Decode(matches.single.group(1)!)))
                as Map<String, dynamic>,
          );
      if (!_validFields(definition, options) ||
          (requireIntactPlayer &&
              matches.single.group(0) != _managedBlock(options)))
        return null;
      if (result != null &&
          jsonEncode(result.toJson()) != jsonEncode(options.toJson()))
        return null;
      result = options;
    } on Object {
      return null;
    }
  }
  return result;
}

bool _validFields(
  AnkiNoteTypeDefinition definition,
  AnkiVideoTemplateOptions options,
) {
  final List<String> fields = <String>[
    options.field,
    ...options.previousFields,
  ];
  return fields.toSet().length == fields.length &&
      fields.every(
        (String field) =>
            definition.fields.contains(field) &&
            !field.contains(RegExp(r'[{}<>\r\n]')),
      );
}

String _managedBlock(AnkiVideoTemplateOptions options) {
  final String metadata = base64Encode(
    utf8.encode(jsonEncode(options.toJson())),
  );
  final List<String> fields = <String>[
    options.field,
    ...options.previousFields,
  ];
  final String sources = <String>[
    for (int index = 0; index < fields.length; index++)
      '<template id="fushi-video-source${index == 0 ? '' : '-$index'}" data-fushi-video-source="1">{{${fields[index]}}}</template>',
  ].join();
  return '$_start$metadata -->'
      '$sources'
      '<div id="fushi-video-player" data-placement="${options.placement.name}" data-autoplay="${options.autoplay}" style="max-width:100%"></div>'
      '<script>$_playerScript</script>$_end';
}

const String _playerScript = r'''
(function(){
  if(window.__fushiVideoCleanup)window.__fushiVideoCleanup();
  var host=document.getElementById('fushi-video-player');
  var sources=Array.from(document.querySelectorAll('template[data-fushi-video-source]'));
  var source=sources.find(function(candidate){
    return candidate.content.querySelector('video[src],audio[src],img[src],[data-fushi-native-video],object,iframe');
  })||sources[0];
  if(!host||!source)return;
  var original=source.content.querySelector('video[src]');
  var nativeMarker=source.content.querySelector('[data-fushi-native-video]');
  if(!original&&!nativeMarker)return;
  var player=null,observer=null,disposed=false,observed=new WeakSet();
  function roots(){
    var list=[document];
    for(var i=0;i<list.length;i++)list[i].querySelectorAll('*').forEach(function(e){if(e.shadowRoot)list.push(e.shadowRoot);});
    return list;
  }
  function observeRoots(){if(!observer)return;roots().forEach(function(root){if(!observed.has(root)){observed.add(root);observer.observe(root,{childList:true,subtree:true});}});}
  function all(selector){var found=[];roots().forEach(function(root){root.querySelectorAll(selector).forEach(function(e){found.push(e);});});return found;}
  function stopCopies(){
    all('video.fushi-inline-video,video.fushi-video-source,audio.fushi-inline-audio').forEach(function(e){
      if(e===player)return;
      e.oncanplay=null;e.removeAttribute('oncanplay');e.removeAttribute('autoplay');e.pause();e.hidden=true;e.preload='none';
    });
  }
  function play(){if(!player)return;player.currentTime=0;var p=player.play();if(p&&p.catch)p.catch(function(){});}
  function nativeReplay(){
    var candidates=all('.fushi-synced-sentence-media .replay-button,.fushi-synced-sentence-media .replaybutton,.fushi-synced-sentence-media .soundLink,[data-field="SentenceAudio"] .replay-button,[data-field="SentenceAudio"] .replaybutton,[data-field="SentenceAudio"] .soundLink,.sentence-audio .replay-button,.sentence-audio .replaybutton,.sentence-audio .soundLink');
    var target=candidates.find(function(e){return !host.contains(e);});
    if(target)target.click();
  }
  if(original){
    player=document.createElement('video');player.src=original.getAttribute('src');player.controls=true;player.playsInline=true;player.preload='metadata';player.style.maxWidth='100%';player.className='fushi-managed-video';host.appendChild(player);
    var replay=document.createElement('button');replay.type='button';replay.textContent='▶';replay.setAttribute('aria-label','Replay video');replay.onclick=play;host.appendChild(replay);
  }else{
    var replay=document.createElement('button');replay.type='button';replay.textContent='▶';replay.setAttribute('aria-label','Replay video');replay.onclick=nativeReplay;host.appendChild(replay);
  }
  function visible(e){return !!e&&!!e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden'&&getComputedStyle(e).display!=='none';}
  function place(){
    stopCopies();
    if(!host.isConnected)source.after(host);
    if(host.dataset.placement!=='picture')return;
    var kiku=all('.picture-field-container').find(function(e){return !!e.getRootNode().host&&visible(e.parentElement);});
    var anchor=kiku||all('video.fushi-video-source,video.fushi-inline-video,[data-fushi-native-video]').find(function(e){return e.isConnected&&!host.contains(e)&&visible(e.parentElement)&&!e.closest('.picture-field-background');});
    if(anchor&&anchor.parentNode&&host.previousSibling!==anchor)anchor.after(host);
    if(!anchor&&host.previousSibling!==source)source.after(host);
  }
  function cleanup(){if(disposed)return;disposed=true;if(observer)observer.disconnect();if(player)player.pause();window.removeEventListener('pagehide',cleanup);}
  window.__fushiVideoCleanup=cleanup;window.addEventListener('pagehide',cleanup);
  place();
  observer=new MutationObserver(function(){if(!source.isConnected){cleanup();return;}observeRoots();place();});
  observeRoots();
  if(player&&host.dataset.autoplay==='true')play();
})();
''';
