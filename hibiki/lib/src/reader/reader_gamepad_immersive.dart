/// TODO-728①: pure decision for the gamepad auto-immersive chrome rule.
///
/// Inputs are the current chrome visibility and whether the chrome was last
/// hidden BY the gamepad path. Output is the next state. Kept as a standalone
/// pure function so the ownership logic (who hid the chrome, who may restore it)
/// is unit-testable without the full reader page.
///
/// Rules:
///  - Controller present + chrome shown  -> hide it, mark gamepad-owned.
///  - Controller present + chrome already hidden -> leave it; do NOT claim
///    ownership (the user may have hidden it).
///  - Controller gone + gamepad-owned hide -> restore + clear ownership.
///  - Controller gone + NOT gamepad-owned -> leave the chrome as-is (a manual
///    toggle in between took ownership; never fight the user).
typedef GamepadImmersiveState = ({bool showChrome, bool hiddenByGamepad});

GamepadImmersiveState resolveGamepadImmersive({
  required bool present,
  required bool showChrome,
  required bool hiddenByGamepad,
}) {
  if (present) {
    if (showChrome) {
      return (showChrome: false, hiddenByGamepad: true);
    }
    return (showChrome: showChrome, hiddenByGamepad: hiddenByGamepad);
  }
  if (hiddenByGamepad) {
    return (showChrome: true, hiddenByGamepad: false);
  }
  return (showChrome: showChrome, hiddenByGamepad: hiddenByGamepad);
}
