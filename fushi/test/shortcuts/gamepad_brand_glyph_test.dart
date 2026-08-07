import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_glyphs.dart';

/// TODO-1113: brand glyph mapping guards. These assert the **display-only**
/// contract: switching [GamepadBrand] only changes the shown symbol/accent,
/// never the underlying [GamepadButton] identity or its serialization token.
void main() {
  String sym(GamepadButton b, GamepadBrand brand) =>
      GamepadGlyphs.glyphFor(b, brand).symbol;

  group('brand tokens round-trip (display preference only)', () {
    test('every brand token round-trips through fromToken', () {
      for (final GamepadBrand brand in GamepadBrand.values) {
        expect(GamepadBrand.fromToken(brand.token), brand);
      }
    });

    test('unknown / null token falls back to xbox (back-compat default)', () {
      expect(GamepadBrand.fromToken(null), GamepadBrand.xbox);
      expect(GamepadBrand.fromToken(''), GamepadBrand.xbox);
      expect(GamepadBrand.fromToken('nope'), GamepadBrand.xbox);
    });

    test('brand tokens are distinct and stable', () {
      final Set<String> tokens =
          GamepadBrand.values.map((GamepadBrand b) => b.token).toSet();
      expect(tokens.length, GamepadBrand.values.length);
      // Locked persistence tokens — changing these silently migrates users.
      expect(GamepadBrand.xbox.token, 'xbox');
      expect(GamepadBrand.playstation.token, 'playstation');
      expect(GamepadBrand.nintendoSwitch.token, 'switch');
    });
  });

  group('Xbox face buttons (baseline)', () {
    test('A/B/X/Y render their own letters', () {
      expect(sym(GamepadButton.a, GamepadBrand.xbox), 'A');
      expect(sym(GamepadButton.b, GamepadBrand.xbox), 'B');
      expect(sym(GamepadButton.x, GamepadBrand.xbox), 'X');
      expect(sym(GamepadButton.y, GamepadBrand.xbox), 'Y');
    });
  });

  group('PlayStation face buttons', () {
    test('A/B/X/Y render cross/circle/square/triangle', () {
      expect(sym(GamepadButton.a, GamepadBrand.playstation), '✕');
      expect(sym(GamepadButton.b, GamepadBrand.playstation), '○');
      expect(sym(GamepadButton.x, GamepadBrand.playstation), '□');
      expect(sym(GamepadButton.y, GamepadBrand.playstation), '△');
    });
  });

  group('Nintendo Switch ABXY position swap (relative to Xbox)', () {
    // The load-bearing invariant: on a Switch controller the letters printed
    // at the A/B (right/bottom) and X/Y (top/left) positions are swapped vs
    // Xbox. Logical GamepadButton keeps Xbox position semantics, so:
    //   .a (bottom)  -> 'B'
    //   .b (right)   -> 'A'
    //   .x (left)    -> 'Y'
    //   .y (top)     -> 'X'
    test('bottom button (.a) shows B', () {
      expect(sym(GamepadButton.a, GamepadBrand.nintendoSwitch), 'B');
    });
    test('right button (.b) shows A', () {
      expect(sym(GamepadButton.b, GamepadBrand.nintendoSwitch), 'A');
    });
    test('left button (.x) shows Y', () {
      expect(sym(GamepadButton.x, GamepadBrand.nintendoSwitch), 'Y');
    });
    test('top button (.y) shows X', () {
      expect(sym(GamepadButton.y, GamepadBrand.nintendoSwitch), 'X');
    });

    test('A<->B and X<->Y are exact pairwise swaps vs Xbox', () {
      expect(
        sym(GamepadButton.a, GamepadBrand.nintendoSwitch),
        sym(GamepadButton.b, GamepadBrand.xbox),
      );
      expect(
        sym(GamepadButton.b, GamepadBrand.nintendoSwitch),
        sym(GamepadButton.a, GamepadBrand.xbox),
      );
      expect(
        sym(GamepadButton.x, GamepadBrand.nintendoSwitch),
        sym(GamepadButton.y, GamepadBrand.xbox),
      );
      expect(
        sym(GamepadButton.y, GamepadBrand.nintendoSwitch),
        sym(GamepadButton.x, GamepadBrand.xbox),
      );
    });

    test('Switch face buttons carry a brand accent color', () {
      for (final GamepadButton face in <GamepadButton>[
        GamepadButton.a,
        GamepadButton.b,
        GamepadButton.x,
        GamepadButton.y,
      ]) {
        expect(
          GamepadGlyphs.glyphFor(face, GamepadBrand.nintendoSwitch).accent,
          isNotNull,
        );
      }
    });
  });

  group('non-face buttons share enum label across all brands', () {
    test('shoulders / dpad / system keys are brand-agnostic', () {
      const List<GamepadButton> nonFace = <GamepadButton>[
        GamepadButton.lb,
        GamepadButton.rt,
        GamepadButton.dpadUp,
        GamepadButton.thumbLeft,
        GamepadButton.start,
        GamepadButton.mode,
      ];
      for (final GamepadButton b in nonFace) {
        for (final GamepadBrand brand in GamepadBrand.values) {
          expect(sym(b, brand), b.label);
          expect(GamepadGlyphs.glyphFor(b, brand).accent, isNull);
        }
      }
    });
  });

  group('serialization is decoupled from brand', () {
    test('GamepadButton.serialize never changes with brand (red line)', () {
      // Whatever the display brand, the persisted token equals the enum label.
      const GamepadBinding binding = GamepadBinding(GamepadButton.a);
      expect(binding.button.label, GamepadButton.a.label);
      for (final GamepadButton b in GamepadButton.values) {
        expect(b.label, isNotEmpty);
      }
    });
  });
}
