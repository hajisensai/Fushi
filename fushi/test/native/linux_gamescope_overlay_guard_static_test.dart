// Source guard for Steam Deck Game Mode (Gamescope) support of the Linux
// out-of-app windows: screen OCR layer, lookup card and the back button.
// Linux native code is not built on the Windows CI runner, so this scans the
// sources for the rules Gamescope imposes (see linux/runner/gamescope_overlay.h).
import 'dart:io';

import 'package:test/test.dart';

void main() {
  String read(String relativeToFushi) {
    final File file = File(relativeToFushi);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  late String gamescope;
  late String capture;
  late String overlay;
  late String card;
  late String channel;
  late String buttons;
  late String cmake;
  late String manifest;
  setUpAll(() {
    gamescope = read('linux/runner/gamescope_overlay.h');
    capture = read('linux/runner/screen_capture.cc');
    overlay = read('linux/runner/screen_ocr_overlay.cc');
    card = read('linux/lookup_card/card_overlay.cc');
    channel = read('linux/runner/floating_ball_channel.cc');
    buttons = read('linux/runner/deck_buttons.cc');
    cmake = read('linux/runner/CMakeLists.txt');
    manifest = read('../tool/linux/flatpak/app.fushi.reader.yml');
  });

  test('Game Mode is detected from the Gamescope root property', () {
    expect(gamescope, contains('"GAMESCOPE_FOCUSED_APP"'));
  });

  test('roles map to the Gamescope and Steam window properties', () {
    for (final String property in <String>[
      'GAMESCOPE_EXTERNAL_OVERLAY',
      'STEAM_OVERLAY',
      'STEAM_INPUT_FOCUS',
      '_NET_WM_WINDOW_OPACITY',
    ]) {
      expect(gamescope, contains('"$property"'), reason: property);
    }
    // Gamescope picks overlays without checking the map state: kNone must
    // delete every property, not just leave the window hidden.
    final int none = gamescope.indexOf('if (role == kNone)');
    final int orElse = gamescope.indexOf('} else {', none);
    expect(none, greaterThan(0));
    expect(
      gamescope.substring(none, orElse),
      allOf(
        contains('"GAMESCOPE_EXTERNAL_OVERLAY"'),
        contains('"STEAM_OVERLAY"'),
        contains('"STEAM_INPUT_FOCUS"'),
      ),
    );
  });

  test('Steam overlay outranks the card, the card outranks the OCR layer', () {
    int rank(String name) {
      final RegExpMatch? match = RegExp(
        'constexpr uint32_t $name = (0x[0-9A-Fa-f]+)u;',
      ).firstMatch(gamescope);
      expect(match, isNotNull, reason: name);
      return int.parse(match!.group(1)!.substring(2), radix: 16);
    }

    const int steamOverlay = 0xFFFFFFFF;
    final int card = rank('kCardRank');
    final int freeze = rank('kFreezeLayerRank');
    expect(card, lessThan(steamOverlay));
    expect(freeze, lessThan(card));
  });

  test('the OCR layer is drawn and takes input; the card only takes input', () {
    expect(
      overlay,
      contains(
        'fushi::gamescope::kDraw | fushi::gamescope::kInput,\n'
        '      fushi::gamescope::kFreezeLayerRank',
      ),
    );
    // As an external overlay the card would outrank the OCR layer for the one
    // drawn external overlay and the frozen frame would disappear.
    expect(card, isNot(contains('kDraw')));
    expect(card, contains('fushi::gamescope::kCardRank'));
  });

  test('the card drops its role whenever it hides', () {
    String body(String signature) {
      final int start = card.indexOf(signature);
      expect(start, greaterThan(0), reason: signature);
      return card.substring(start, card.indexOf('\n}\n', start));
    }

    expect(
      body('void CardOverlay::Hide(bool notify)'),
      contains('fushi::gamescope::kNone'),
    );
    expect(
      body('bool CardOverlay::SuspendForCapture(int64_t generation)'),
      contains('fushi::gamescope::kNone'),
    );
  });

  test('the card covers the output in Game Mode and moves inside it', () {
    expect(card, contains('gtk_fixed_new()'));
    expect(card, contains('gtk_fixed_move(GTK_FIXED(stage_), web_view_'));
  });

  test('Gamescope focus changes do not close the card', () {
    final int start = card.indexOf('void CardOverlay::OnActiveWindowChanged()');
    final int read = card.indexOf('ReadActiveWindow()', start);
    expect(
      card.substring(start, read),
      contains('fushi::gamescope::InGameMode()'),
    );
  });

  test('Game Mode captures the Gamescope PipeWire node, never the X root', () {
    expect(capture, contains('pipewiresrc target-object=gamescope'));
    final int route = capture.indexOf('if (fushi::gamescope::InGameMode())');
    final int portal = capture.indexOf('if (IsWaylandSession())', route);
    expect(route, greaterThan(0));
    expect(portal, greaterThan(route));
    // Without GStreamer the Game Mode branch fails instead of falling through
    // to the X root (Steam's display, not the game).
    expect(
      capture.substring(route, portal),
      allOf(contains('"capture_failed"'), contains('return;')),
    );
    expect(cmake, contains('FUSHI_GAMESCOPE_CAPTURE'));
    expect(cmake, contains('"deck_buttons.cc"'));
    expect(manifest, contains('--filesystem=xdg-run/pipewire-0'));
    expect(manifest, contains('--device=all'));
  });

  test('R4 toggles screen OCR through the ball action route', () {
    expect(channel, contains('BackButton::kR4'));
    expect(channel, contains('DismissByUser()'));
    expect(channel, contains('"systemBallAction"'));
    expect(channel, contains('fl_value_new_string("screen_ocr")'));
    // The reader thread is joined before the object it calls into is freed.
    final int free = channel.indexOf('void fushi_floating_ball_free(');
    expect(
      channel.indexOf('self->deck_button.reset();', free),
      lessThan(channel.indexOf('self->screen_ocr.reset();', free)),
    );
  });

  test('back button masks match the Fushi Lens plugin table', () {
    final String python = read(
      '../tools/decky-fushi-lens/py_modules/fushi_lens/paddles.py',
    );
    for (final String name in <String>['L4', 'R4', 'L5', 'R5']) {
      final RegExpMatch? lens = RegExp(
        '"$name": \\(([01]), (0x[0-9A-Fa-f]+)\\)',
      ).firstMatch(python);
      final RegExpMatch? native = RegExp(
        'case BackButton::k$name:\\n\\s*return \\{([01]), (0x[0-9A-Fa-f]+)u\\};',
      ).firstMatch(buttons);
      expect(lens, isNotNull, reason: 'lens $name');
      expect(native, isNotNull, reason: 'native $name');
      expect(native!.group(1), lens!.group(1), reason: name);
      expect(
        int.parse(native.group(2)!.substring(2), radix: 16),
        int.parse(lens.group(2)!.substring(2), radix: 16),
        reason: name,
      );
    }
    // Read-only: the controller is never written to or grabbed.
    expect(buttons, contains('O_RDONLY'));
    expect(buttons, isNot(contains('O_RDWR')));
    expect(buttons, isNot(contains('EVIOCGRAB')));
  });
}
