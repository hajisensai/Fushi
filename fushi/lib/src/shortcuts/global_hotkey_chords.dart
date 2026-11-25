import 'package:flutter/services.dart' hide ModifierKey;
import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

/// Maps a registry keyboard [binding] to the platform-neutral chord the
/// app-outside hotkey backends take. The registry stores a logical key +
/// [ModifierKey] set; [InputBinding.physicalKey] gives the USB-HID key the
/// native backend registers (same US-QWERTY table normalizeCapturedKey
/// indexes), and the xkb keysym name for the portal's preferred trigger is
/// derived from that physical key. Returns null when the logical key has no
/// physical mapping (game* / numpad keys, not valid global hotkeys anyway).
GlobalHotKeyChord? globalHotKeyChordFor(InputBinding binding) {
  final PhysicalKeyboardKey? physical = binding.physicalKey;
  if (physical == null) return null;
  return GlobalHotKeyChord(
    physicalUsage: physical.usbHidUsage,
    keysym: xkbKeysymNameFor(physical),
    modifiers: <GlobalHotKeyModifier>{
      for (final ModifierKey mod in binding.modifiers)
        switch (mod) {
          ModifierKey.ctrl => GlobalHotKeyModifier.ctrl,
          ModifierKey.shift => GlobalHotKeyModifier.shift,
          ModifierKey.alt => GlobalHotKeyModifier.alt,
          ModifierKey.meta => GlobalHotKeyModifier.meta,
        },
    },
    label: binding.displayLabel,
  );
}

/// xkb keysym name (xkbcommon-keysyms.h without `XKB_KEY_`) of the US-QWERTY
/// base-layer symbol on [physical]; null for keys without one here. The XDG
/// shortcuts spec limits triggers to the base layer, so letters are lower case.
String? xkbKeysymNameFor(PhysicalKeyboardKey physical) {
  final int usage = physical.usbHidUsage;
  // Letters: HID 0x00070004 (A) .. 0x0007001d (Z).
  if (usage >= PhysicalKeyboardKey.keyA.usbHidUsage &&
      usage <= PhysicalKeyboardKey.keyZ.usbHidUsage) {
    return String.fromCharCode(
      0x61 + usage - PhysicalKeyboardKey.keyA.usbHidUsage,
    );
  }
  // Digits: HID 1..9 then 0.
  if (usage >= PhysicalKeyboardKey.digit1.usbHidUsage &&
      usage <= PhysicalKeyboardKey.digit9.usbHidUsage) {
    return '${1 + usage - PhysicalKeyboardKey.digit1.usbHidUsage}';
  }
  if (usage >= PhysicalKeyboardKey.f1.usbHidUsage &&
      usage <= PhysicalKeyboardKey.f12.usbHidUsage) {
    return 'F${1 + usage - PhysicalKeyboardKey.f1.usbHidUsage}';
  }
  return _namedKeysyms[physical];
}

final Map<PhysicalKeyboardKey, String> _namedKeysyms =
    <PhysicalKeyboardKey, String>{
      PhysicalKeyboardKey.digit0: '0',
      PhysicalKeyboardKey.space: 'space',
      PhysicalKeyboardKey.escape: 'Escape',
      PhysicalKeyboardKey.enter: 'Return',
      PhysicalKeyboardKey.tab: 'Tab',
      PhysicalKeyboardKey.backspace: 'BackSpace',
      PhysicalKeyboardKey.delete: 'Delete',
      PhysicalKeyboardKey.insert: 'Insert',
      PhysicalKeyboardKey.home: 'Home',
      PhysicalKeyboardKey.end: 'End',
      PhysicalKeyboardKey.pageUp: 'Page_Up',
      PhysicalKeyboardKey.pageDown: 'Page_Down',
      PhysicalKeyboardKey.arrowUp: 'Up',
      PhysicalKeyboardKey.arrowDown: 'Down',
      PhysicalKeyboardKey.arrowLeft: 'Left',
      PhysicalKeyboardKey.arrowRight: 'Right',
      PhysicalKeyboardKey.minus: 'minus',
      PhysicalKeyboardKey.equal: 'equal',
      PhysicalKeyboardKey.bracketLeft: 'bracketleft',
      PhysicalKeyboardKey.bracketRight: 'bracketright',
      PhysicalKeyboardKey.backslash: 'backslash',
      PhysicalKeyboardKey.semicolon: 'semicolon',
      PhysicalKeyboardKey.quote: 'apostrophe',
      PhysicalKeyboardKey.backquote: 'grave',
      PhysicalKeyboardKey.comma: 'comma',
      PhysicalKeyboardKey.period: 'period',
      PhysicalKeyboardKey.slash: 'slash',
    };
