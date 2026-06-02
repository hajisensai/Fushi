# Hibiki LAN Discovery (Bonsoir) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Hibiki 互联 (the `hibikiServer` P2P backend) devices discover each other on the LAN by adding the missing *advertise* half — host devices broadcast a Zeroconf service while every device browses for it.

**Architecture:** Replace the query-only `multicast_dns` client with the federated `bonsoir` plugin, which supports both broadcast and discovery on all 5 shipping platforms. The host (the device running `HibikiSyncServer`) starts a `BonsoirBroadcast` advertising `_hibiki-sync._tcp` on the server port with the device id/name in TXT attributes; the discovery UI starts a `BonsoirDiscovery`, resolves each found service, and lists peers (filtering out self by device id). Broadcast lifecycle is bound to the sync-server start/stop in `_ServerModeWidget`; discovery lifecycle stays in `_LanDiscoveryWidget`.

**Tech Stack:** Flutter 3.41.6 / Dart 3.11.4, `bonsoir` (federated: android/darwin/windows/linux), Drift preferences for the persisted device id.

**Root cause (why this work exists):** `LanDiscoveryService` only ever called `MDnsClient.lookup(...)` for `_hibiki-sync._tcp.local`. `multicast_dns` is a resolver-only library — it cannot register/answer a service, and nothing else in the app advertised one. Both peers queried; nobody answered; the device list was always empty.

**Known platform constraints (carry these into testing):**
- iOS: Bonsoir needs deployment target ≥ 13.0 (currently 12.0 — bumped in Task 6). iOS 14+/macOS 11+ require `NSLocalNetworkUsageDescription` + `NSBonjourServices` listing `_hibiki-sync._tcp` in Info.plist, or the OS silently blocks both advertise and browse and shows a permission prompt on first use.
- Android: min API 24 already satisfies Bonsoir's 21 floor; TXT attributes work (the Android-6-and-below attribute bug doesn't apply).
- Windows: needs Windows 10 1903+ (WIN32 DNS-SD API). No build-time setup.
- Linux: needs the `avahi-daemon` running at runtime (Bonsoir talks to it over D-Bus). Build-time: nothing.
- **Bonsoir cannot be meaningfully tested on a single Android emulator** — an emulator only discovers services it broadcasts itself. Automated cross-device discovery is therefore NOT covered by `ci/integration-test.sh`; end-to-end verification is the two-device manual recipe in Task 9. Unit tests cover the pure mapping/identity logic.

---

## File Structure

- `hibiki/pubspec.yaml` — swap `multicast_dns` → `bonsoir`.
- `hibiki/lib/src/sync/lan_discovery_service.dart` — **modify**: keep `HibikiDevice` + the `LanDiscoveryService` browse surface, but reimplement browsing on `BonsoirDiscovery`; add a pure `HibikiDevice.fromResolvedService(...)` mapper; add `LanBroadcastService` (advertise) in the same file (browse + advertise change together, share the service-type/attribute-key constants).
- `hibiki/lib/src/sync/sync_repository.dart` — **modify**: add a persisted, device-local `sync_device_id` (stable identity for self-filtering + TXT) and add it to `deviceLocalPrefKeys`.
- `hibiki/lib/src/sync/sync_settings_schema.dart` — **modify**: in `_ServerModeWidget`, start/stop `LanBroadcastService` alongside the `HibikiSyncServer`; pass the device id + name + bound port.
- `hibiki/ios/Runner/Info.plist`, `hibiki/macos/Runner/Info.plist` — **modify**: add Bonjour service + local-network usage keys.
- `hibiki/ios/Podfile`, `hibiki/ios/Runner.xcodeproj/project.pbxproj` — **modify**: bump iOS deployment target 12.0 → 13.0.
- `hibiki/test/sync/lan_discovery_service_test.dart` — **create**: unit tests for the pure mapper + device identity (no real network).
- `hibiki/test/sync/sync_repository_test.dart` — **modify**: assert `sync_device_id` is stable + device-local.

---

### Task 1: Add a stable, device-local device id to SyncRepository

**Files:**
- Modify: `hibiki/lib/src/sync/sync_repository.dart`
- Test: `hibiki/test/sync/sync_repository_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `hibiki/test/sync/sync_repository_test.dart` (inside the existing top-level `main()` group; mirror the file's existing in-memory DB setup — reuse the same `HibikiDatabase` test helper already imported there):

```dart
test('getOrCreateDeviceId is stable across calls', () async {
  final repo = SyncRepository(db);
  final first = await repo.getOrCreateDeviceId();
  expect(first, isNotEmpty);
  final second = await repo.getOrCreateDeviceId();
  expect(second, equals(first));
});

test('sync_device_id is in the device-local key catalog', () {
  expect(SyncRepository.deviceLocalPrefKeys, contains('sync_device_id'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/sync/sync_repository_test.dart`
Expected: FAIL — `getOrCreateDeviceId` is undefined / `sync_device_id` not in list.

- [ ] **Step 3: Add the key, accessor, and catalog entry**

In `sync_repository.dart`, in the "Hibiki Server config" region add the key constant next to `_keyServerEnabled`:

```dart
  static const _keyDeviceId = 'sync_device_id';
```

Add the accessor (place it after `setServerPassword`):

```dart
  /// Stable per-install identifier used to (a) advertise this device over the
  /// LAN and (b) filter our own service out of discovery results. Generated
  /// once on first use and persisted; never overwritten by a backup import.
  Future<String> getOrCreateDeviceId() async {
    final existing = await _getStringOrNull(_keyDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final String id = HibikiSyncServer.generateToken();
    await _setString(_keyDeviceId, id);
    return id;
  }
```

Add `import 'package:hibiki/src/sync/hibiki_sync_server.dart';` at the top if not present (reuses the existing CSPRNG token generator — no new dependency).

Add `_keyDeviceId` to the `deviceLocalPrefKeys` list (it identifies *this* device, so it must survive a backup import like the other server keys):

```dart
    _keyServerEnabled,
    _keyServerPort,
    _keyServerPassword,
    _keyDeviceId,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/sync/sync_repository_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/sync_repository.dart hibiki/test/sync/sync_repository_test.dart
git commit -m "feat(sync): add stable device-local sync_device_id"
```

---

### Task 2: Swap the dependency multicast_dns → bonsoir

**Files:**
- Modify: `hibiki/pubspec.yaml`

- [ ] **Step 1: Remove multicast_dns, add bonsoir**

In `hibiki/pubspec.yaml`, delete the `multicast_dns: ^0.3.2+6` line, then run:

```bash
cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat pub add bonsoir
```

This resolves and pins the latest compatible `bonsoir` (federated plugin) into `pubspec.yaml` and updates `pubspec.lock`.

- [ ] **Step 2: Verify it resolves**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat pub get`
Expected: `Got dependencies!` with `bonsoir`, `bonsoir_android`, `bonsoir_darwin`, `bonsoir_windows`, `bonsoir_linux`, `bonsoir_platform_interface` present in `pubspec.lock`.

- [ ] **Step 3: Confirm no remaining references to the old package**

Run: `cd hibiki && grep -rn "multicast_dns\|MDnsClient\|ResourceRecordQuery\|PtrResourceRecord" lib test`
Expected: only matches inside `lib/src/sync/lan_discovery_service.dart` (rewritten in Task 3). If anything else matches, it must be migrated in this plan — stop and flag it.

- [ ] **Step 4: Commit**

```bash
git add hibiki/pubspec.yaml hibiki/pubspec.lock
git commit -m "build(sync): replace multicast_dns with bonsoir"
```

---

### Task 3: Reimplement LanDiscoveryService on Bonsoir + add LanBroadcastService

**Files:**
- Modify: `hibiki/lib/src/sync/lan_discovery_service.dart`
- Test: `hibiki/test/sync/lan_discovery_service_test.dart` (create)

- [ ] **Step 1: Write the failing test for the pure mapper + self-filter**

Create `hibiki/test/sync/lan_discovery_service_test.dart`:

```dart
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';

void main() {
  group('HibikiDevice.fromResolvedService', () {
    BonsoirService svc({
      String name = 'Hibiki on Mac',
      int port = 38765,
      List<String> hostAddresses = const <String>['192.168.1.50'],
      Map<String, String> attributes = const <String, String>{'id': 'dev-abc'},
    }) =>
        BonsoirService(
          name: name,
          type: LanDiscoveryService.serviceType,
          port: port,
          attributes: attributes,
        ).copyWith(hostAddresses: hostAddresses);

    test('maps a resolved service to a HibikiDevice', () {
      final HibikiDevice? d = HibikiDevice.fromResolvedService(svc());
      expect(d, isNotNull);
      expect(d!.name, 'Hibiki on Mac');
      expect(d.port, 38765);
      expect(d.host, '192.168.1.50');
      expect(d.deviceId, 'dev-abc');
      expect(d.webDavUrl, 'http://192.168.1.50:38765');
    });

    test('prefers an IPv4 address over IPv6', () {
      final HibikiDevice? d = HibikiDevice.fromResolvedService(
        svc(hostAddresses: <String>['fe80::1', '192.168.1.51']),
      );
      expect(d!.host, '192.168.1.51');
    });

    test('returns null when no host address is resolved', () {
      final HibikiDevice? d =
          HibikiDevice.fromResolvedService(svc(hostAddresses: const <String>[]));
      expect(d, isNull);
    });

    test('falls back to the service name when no id attribute is present', () {
      final HibikiDevice? d = HibikiDevice.fromResolvedService(
        svc(attributes: const <String, String>{}),
      );
      expect(d!.deviceId, 'Hibiki on Mac');
    });
  });
}
```

> Note: if `BonsoirService.copyWith(hostAddresses:)` is not the exact shape in the resolved version of the package, adjust the helper to set `hostAddresses` via whatever constructor/field the installed `bonsoir` exposes (check `flutter pub deps` / the package source). The mapper under test reads `service.hostAddresses`, `service.name`, `service.port`, `service.attributes` — keep those reads stable.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/sync/lan_discovery_service_test.dart`
Expected: FAIL — `fromResolvedService` undefined.

- [ ] **Step 3: Rewrite `lan_discovery_service.dart`**

Replace the whole file with:

```dart
import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// A peer Hibiki instance discovered on the LAN.
class HibikiDevice {
  HibikiDevice({
    required this.name,
    required this.host,
    required this.port,
    required this.deviceId,
  });

  final String name;
  final String host;
  final int port;
  final String deviceId;

  String get webDavUrl => 'http://$host:$port';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'host': host,
        'port': port,
        'deviceId': deviceId,
      };

  factory HibikiDevice.fromJson(Map<String, dynamic> json) => HibikiDevice(
        name: json['name'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        deviceId: json['deviceId'] as String,
      );

  /// Builds a device from a *resolved* Bonsoir service. Returns null when the
  /// platform resolved no usable IPv4/IPv6 address (an unusable peer we cannot
  /// connect to). Prefers IPv4 because [HibikiSyncServer] binds IPv4.
  static HibikiDevice? fromResolvedService(BonsoirService service) {
    final List<String> addrs = service.hostAddresses;
    if (addrs.isEmpty) return null;
    final String host = addrs.firstWhere(
      (String a) => !a.contains(':'),
      orElse: () => addrs.first,
    );
    return HibikiDevice(
      name: service.name,
      host: host,
      port: service.port,
      deviceId: service.attributes[LanDiscoveryService.attributeId] ??
          service.name,
    );
  }
}

/// Browses the LAN for peer Hibiki sync servers advertised via [serviceType].
class LanDiscoveryService {
  LanDiscoveryService({required this.deviceId});

  static const String serviceType = '_hibiki-sync._tcp';

  /// TXT attribute key carrying the advertiser's stable device id.
  static const String attributeId = 'id';

  /// Our own device id, used to filter our own advertisement out of results.
  final String deviceId;

  final Map<String, HibikiDevice> _discoveredDevices = <String, HibikiDevice>{};
  final StreamController<List<HibikiDevice>> _deviceStream =
      StreamController<List<HibikiDevice>>.broadcast();
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  Stream<List<HibikiDevice>> get devices => _deviceStream.stream;
  List<HibikiDevice> get currentDevices => _discoveredDevices.values.toList();

  Future<void> startDiscovery() async {
    final BonsoirDiscovery discovery = BonsoirDiscovery(type: serviceType);
    _discovery = discovery;
    await discovery.initialize();
    _sub = discovery.eventStream!.listen(_onEvent);
    await discovery.start();
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        // Resolution yields the host addresses + TXT attributes we need.
        event.service.resolve(_discovery!.serviceResolver);
      case BonsoirDiscoveryServiceResolvedEvent():
        final HibikiDevice? device =
            HibikiDevice.fromResolvedService(event.service);
        if (device != null && device.deviceId != deviceId) {
          _discoveredDevices[device.deviceId] = device;
          _deviceStream.add(currentDevices);
        }
      case BonsoirDiscoveryServiceLostEvent():
        final String? id = event.service.attributes[attributeId];
        if (id != null) {
          _discoveredDevices.remove(id);
          _deviceStream.add(currentDevices);
        }
      default:
        break;
    }
  }

  Future<void> stopDiscovery() async {
    await _sub?.cancel();
    _sub = null;
    await _discovery?.stop();
    _discovery = null;
    _discoveredDevices.clear();
    _deviceStream.add(<HibikiDevice>[]);
  }

  Future<void> dispose() async {
    await stopDiscovery();
    await _deviceStream.close();
  }
}

/// Advertises this device as a Hibiki sync server so peers can discover it.
/// Lifecycle is bound to the running [HibikiSyncServer] in `_ServerModeWidget`.
class LanBroadcastService {
  LanBroadcastService({
    required this.deviceName,
    required this.deviceId,
    required this.port,
  });

  final String deviceName;
  final String deviceId;
  final int port;

  BonsoirBroadcast? _broadcast;

  bool get isBroadcasting => _broadcast != null;

  Future<void> start() async {
    if (_broadcast != null) return;
    final BonsoirService service = BonsoirService(
      name: deviceName,
      type: LanDiscoveryService.serviceType,
      port: port,
      attributes: <String, String>{LanDiscoveryService.attributeId: deviceId},
    );
    final BonsoirBroadcast broadcast = BonsoirBroadcast(service: service);
    try {
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (e, stack) {
      // Advertising failure (no Avahi on Linux, blocked local-network perm on
      // iOS, etc.) must not kill the already-running HTTP server — log and
      // leave the server reachable by manually-entered URL (HBK-AUDIT-style).
      ErrorLogService.instance.log('LanBroadcast.start', e, stack);
      _broadcast = null;
    }
  }

  Future<void> stop() async {
    await _broadcast?.stop();
    _broadcast = null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/sync/lan_discovery_service_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/lan_discovery_service.dart hibiki/test/sync/lan_discovery_service_test.dart
git commit -m "feat(sync): browse + advertise LAN peers via bonsoir"
```

---

### Task 4: Wire discovery UI to the new device-id constructor

**Files:**
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart` (`_LanDiscoveryWidget`, ~lines 1853-1908)

- [ ] **Step 1: Load the real device id before constructing discovery**

`_LanDiscoveryServiceState.initState` currently builds `LanDiscoveryService(deviceName: 'Hibiki', port: defaultServerPort, deviceId: 'settings-scan')`. The new ctor is `LanDiscoveryService({required deviceId})`. Replace the synchronous construction with an async load of the persisted id. Change the state fields + `initState` + add `_init`:

```dart
  LanDiscoveryService? _discovery;
  // ...existing _devices/_scanning/_scanFailed/_devicesSub fields stay...

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final String deviceId = await SyncRepository(
            widget.settingsContext.appModel.database)
        .getOrCreateDeviceId();
    if (!mounted) return;
    _discovery = LanDiscoveryService(deviceId: deviceId);
    await _startScan();
  }
```

In `dispose`, guard the now-nullable field:

```dart
  @override
  void dispose() {
    _devicesSub?.cancel();
    _discovery?.dispose();
    super.dispose();
  }
```

In `_startScan`, guard against a not-yet-initialized discovery and use the field:

```dart
  Future<void> _startScan() async {
    final LanDiscoveryService? discovery = _discovery;
    if (discovery == null) return;
    setState(() {
      _scanning = true;
      _scanFailed = false;
    });
    _devicesSub = discovery.devices.listen((List<HibikiDevice> devices) {
      if (mounted) setState(() => _devices = devices);
    });
    try {
      await discovery.startDiscovery();
    } catch (e, stack) {
      ErrorLogService.instance.log('LanDiscovery.scan', e, stack);
      if (mounted) setState(() => _scanFailed = true);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }
```

(`_connectToDevice` is unchanged — it still reads `device.webDavUrl` and `device.name`.)

- [ ] **Step 2: Verify it analyzes clean**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/sync/sync_settings_schema.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/sync/sync_settings_schema.dart
git commit -m "feat(sync): drive LAN discovery with the persisted device id"
```

---

### Task 5: Advertise while the host server runs

**Files:**
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart` (`_ServerModeWidgetState`, ~lines 1636-1748)

- [ ] **Step 1: Add a broadcast field + import**

Ensure the file imports `LanBroadcastService` (it already imports `lan_discovery_service.dart`). Add to `_ServerModeWidgetState`:

```dart
  LanBroadcastService? _broadcast;
```

- [ ] **Step 2: Start advertising after the server binds**

In `_startServer()`, immediately after the `await SyncRepository(...).setServerEnabled(true);` line inside the success path (after `_server!.start()` succeeds), start the broadcast using the *actual bound port*:

```dart
      await SyncRepository(widget.settingsContext.appModel.database)
          .setServerEnabled(true);
      await _startBroadcast(_server!.port);
      if (mounted) setState(() {});
```

Add the helper:

```dart
  Future<void> _startBroadcast(int boundPort) async {
    final SyncRepository repo =
        SyncRepository(widget.settingsContext.appModel.database);
    final String deviceId = await repo.getOrCreateDeviceId();
    _broadcast = LanBroadcastService(
      deviceName: _deviceName(),
      deviceId: deviceId,
      port: boundPort,
    );
    await _broadcast!.start();
  }

  /// A human-readable advertisement name. Platform.localHostname is the
  /// machine name on desktop; on mobile it falls back to a generic label.
  String _deviceName() {
    try {
      final String host = Platform.localHostname;
      if (host.trim().isNotEmpty) return 'Hibiki · $host';
    } catch (_) {/* localHostname can throw on some platforms */}
    return 'Hibiki';
  }
```

(`Platform` is already imported via `dart:io` at the top of the file.)

- [ ] **Step 3: Stop advertising when the server stops / widget disposes**

In `_stopServer()`:

```dart
  Future<void> _stopServer() async {
    await _broadcast?.stop();
    _broadcast = null;
    await _server?.stop();
    _server = null;
    if (mounted) setState(() {});
  }
```

In `dispose()` add broadcast teardown before `_server?.stop()`:

```dart
  @override
  void dispose() {
    _portController.dispose();
    _broadcast?.stop();
    _server?.stop();
    super.dispose();
  }
```

In `_regenerateToken()` the existing stop/start already cycles the server; no broadcast change needed (token isn't advertised). Leave as-is.

- [ ] **Step 4: Verify it analyzes clean**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/sync/sync_settings_schema.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/sync_settings_schema.dart
git commit -m "feat(sync): advertise host server over LAN while running"
```

---

### Task 6: iOS — bump deployment target to 13.0

**Files:**
- Modify: `hibiki/ios/Podfile:2`
- Modify: `hibiki/ios/Runner.xcodeproj/project.pbxproj` (3× `IPHONEOS_DEPLOYMENT_TARGET = 12.0;`)

- [ ] **Step 1: Bump the Podfile platform**

In `hibiki/ios/Podfile`, change:

```ruby
platform :ios, '12.0'
```
to
```ruby
platform :ios, '13.0'
```

- [ ] **Step 2: Bump the Xcode project setting**

In `hibiki/ios/Runner.xcodeproj/project.pbxproj`, replace all three occurrences:

```
IPHONEOS_DEPLOYMENT_TARGET = 12.0;
```
with
```
IPHONEOS_DEPLOYMENT_TARGET = 13.0;
```

- [ ] **Step 3: Verify**

Run: `cd hibiki && grep -nE "platform :ios|IPHONEOS_DEPLOYMENT_TARGET" ios/Podfile ios/Runner.xcodeproj/project.pbxproj`
Expected: every line shows `13.0`.

- [ ] **Step 4: Commit**

```bash
git add hibiki/ios/Podfile hibiki/ios/Runner.xcodeproj/project.pbxproj
git commit -m "build(ios): raise deployment target to 13.0 for bonsoir"
```

> iOS/macOS build verification (pod install + simulator build) happens on the remote Mac per the repo's iOS build section — see Task 9 manual recipe. It cannot run on Windows.

---

### Task 7: iOS & macOS — declare the Bonjour service + local-network usage

**Files:**
- Modify: `hibiki/ios/Runner/Info.plist`
- Modify: `hibiki/macos/Runner/Info.plist`

- [ ] **Step 1: Add the keys to iOS Info.plist**

Inside the top-level `<dict>` of `hibiki/ios/Runner/Info.plist`, add:

```xml
	<key>NSLocalNetworkUsageDescription</key>
	<string>Hibiki finds other Hibiki devices on your local network to sync your library.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_hibiki-sync._tcp</string>
	</array>
```

- [ ] **Step 2: Add the same keys to macOS Info.plist**

Inside the top-level `<dict>` of `hibiki/macos/Runner/Info.plist`, add the identical block. (macOS entitlements already grant `com.apple.security.network.server` + `.client`, so no entitlement change is needed.)

- [ ] **Step 3: Verify plist validity**

Run: `cd hibiki && grep -n "NSBonjourServices\|_hibiki-sync._tcp\|NSLocalNetworkUsageDescription" ios/Runner/Info.plist macos/Runner/Info.plist`
Expected: both files list all three markers.

- [ ] **Step 4: Commit**

```bash
git add hibiki/ios/Runner/Info.plist hibiki/macos/Runner/Info.plist
git commit -m "build(apple): declare _hibiki-sync bonjour service + local-network usage"
```

---

### Task 8: Full static verification + regression test sweep

**Files:** none (verification only)

- [ ] **Step 1: Analyze the whole app**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze`
Expected: No issues found (or only pre-existing unrelated infos — compare against a clean baseline if unsure).

- [ ] **Step 2: Run the sync test suite**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub test/sync/`
Expected: all pass, including the new `lan_discovery_service_test.dart`, `sync_repository_test.dart`, and the existing `sync_settings_visibility_test.dart`.

- [ ] **Step 3: Run the full unit/widget suite (catch collateral breakage)**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test --no-pub`
Expected: green. If `multicast_dns` was referenced by any other test, it surfaces here.

- [ ] **Step 4: Android release build (manifest/permission/plugin smoke)**

Adding a federated plugin pulls `bonsoir_android` native code; confirm the Android build still assembles:

Run: `cd hibiki/android && ./gradlew.bat :app:assembleRelease`
Expected: BUILD SUCCESSFUL. (Per repo rules, Android packaging changes require this.)

- [ ] **Step 5: Commit (only if any lock/build artifacts changed)**

```bash
git status --short
# commit only intended files if anything changed; otherwise nothing to do
```

---

### Task 9: Manual two-device verification (the only true end-to-end test)

**Files:** none (manual; Bonsoir cannot be cross-device-tested on one emulator)

- [ ] **Step 1: Host on a desktop build**

On Windows (or the remote Mac), run Hibiki, open Settings → Sync & Backup → set backend to **Hibiki 互联**, enable **本机作为同步服务器**. Confirm the server shows "running" with a port.

- [ ] **Step 2: Browse from a second device on the same Wi-Fi/LAN**

On a physical Android/iOS device (NOT an emulator) on the same subnet, open the same screen with backend **Hibiki 互联**. The host should appear in the LAN devices list within ~5-10s. Tapping it fills the client URL.

- [ ] **Step 3: Confirm the reverse direction**

Enable the server on the second device too; the first device's discovery list should now show it. This proves both advertise and browse work.

- [ ] **Step 4: Negative/permission checks**

- iOS first run: confirm the local-network permission prompt appears; after allowing, discovery works.
- Linux host: confirm `systemctl status avahi-daemon` is active; without it, broadcast logs a `LanBroadcast.start` error and the server stays reachable only by manual URL (expected, documented behavior).

- [ ] **Step 5: Record evidence**

Save screenshots / notes under `.codex-test/` and, if a regression is found, update `docs/REGRESSION_BUGS.md`.

---

## Self-Review

**Spec coverage:**
- Missing advertise half → Task 3 (`LanBroadcastService`) + Task 5 (lifecycle wiring). ✓
- Browse must keep working → Task 3 (`BonsoirDiscovery`) + Task 4 (UI wiring). ✓
- Stable identity for self-filter + TXT → Task 1. ✓
- Dependency swap → Task 2. ✓
- 5-platform enablement: iOS target Task 6, Apple plist Task 7, Android build check Task 8.4, Windows (no setup, covered by 8/9), Linux (runtime avahi, documented in Task 9.4). ✓

**Placeholder scan:** No TBD/“handle errors”/“similar to” — every code step shows full code. The one explicit caveat (Bonsoir `copyWith(hostAddresses:)` shape in Task 3 Step 1) is a verification instruction with a concrete fallback, not a placeholder.

**Type consistency:** `LanDiscoveryService({required deviceId})` (Task 3) matches its use in Task 4. `LanBroadcastService({deviceName, deviceId, port})` (Task 3) matches Task 5. `getOrCreateDeviceId()` (Task 1) is called identically in Tasks 4 and 5. `HibikiDevice.fromResolvedService` reads `service.hostAddresses/name/port/attributes` consistently between Task 3 impl and test. Constant `LanDiscoveryService.attributeId = 'id'` used in mapper, broadcast, and lost-event handler.

**Open risk to watch during execution:** the installed `bonsoir` API surface (event class names like `BonsoirDiscoveryServiceFoundEvent`, `serviceResolver`, `BonsoirService.hostAddresses`) is per the current pub.dev docs; if the resolved version differs, adjust the event handling in Task 3 Step 3 to match the package source (the *structure* — found→resolve→resolved→build device, lost→remove — stays the same).
