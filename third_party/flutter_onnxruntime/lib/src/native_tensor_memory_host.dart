// Fushi fork (PATCHES.md delta 19, BUG-5508).

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Test-only override of whether the host process hands tensors over as native
/// memory. Null means "ask the real OS" ([hostSupportsNativeTensorMemory]).
///
/// Lets host-side tests drive the Android address path without faking the UI
/// target platform: `debugDefaultTargetPlatformOverride` only changes how the
/// UI looks, while the address path depends on the plugin the process really
/// talks to.
@visibleForTesting
bool? debugNativeTensorMemoryHostOverride;

/// [osIsAndroid] unless a test set [debugNativeTensorMemoryHostOverride].
bool resolveNativeTensorMemoryHost(bool osIsAndroid) => debugNativeTensorMemoryHostOverride ?? osIsAndroid;
