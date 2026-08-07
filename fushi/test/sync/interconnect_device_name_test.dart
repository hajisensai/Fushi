import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/interconnect_device_name.dart';
import 'package:fushi_platform/fushi_platform.dart';
import 'package:http/http.dart' as http;

/// A [PlatformDeviceInfoService] whose [deviceModel] is fully controllable, so
/// the advertise-name resolver can be exercised for every platform outcome
/// (mobile "localhost", real model, empty, throwing).
class _FakeDeviceInfo implements PlatformDeviceInfoService {
  _FakeDeviceInfo(this._model, {this.throws = false});
  final String? _model;
  final bool throws;

  @override
  Future<String?> get deviceModel async {
    if (throws) throw const OSError('localHostname failed');
    return _model;
  }

  @override
  Future<int?> get sdkVersion async => null;
  @override
  Future<String?> get manufacturer async => null;
}

void main() {
  group('isMeaninglessDeviceName', () {
    test('flags localhost / loopback literals / empty as meaningless', () {
      expect(isMeaninglessDeviceName('localhost'), isTrue);
      expect(isMeaninglessDeviceName('LOCALHOST'), isTrue);
      expect(isMeaninglessDeviceName('  localhost '), isTrue);
      expect(isMeaninglessDeviceName('127.0.0.1'), isTrue);
      expect(isMeaninglessDeviceName('::1'), isTrue);
      expect(isMeaninglessDeviceName('0.0.0.0'), isTrue);
      expect(isMeaninglessDeviceName(''), isTrue);
      expect(isMeaninglessDeviceName('   '), isTrue);
    });

    test('keeps real device names / hostnames', () {
      expect(isMeaninglessDeviceName('Pixel 7'), isFalse);
      expect(isMeaninglessDeviceName('DESKTOP-A1B2C3'), isFalse);
      expect(isMeaninglessDeviceName("John's iPhone"), isFalse);
      // Not the bare loopback literal; a real name that merely contains it.
      expect(isMeaninglessDeviceName('Hibiki · localhost'), isFalse);
    });
  });

  group('resolveInterconnectDeviceName', () {
    test(
        'mobile "localhost" hostname resolves to the generic label, never '
        'advertising localhost (TODO-1356)', () async {
      final String name =
          await resolveInterconnectDeviceName(_FakeDeviceInfo('localhost'));
      expect(name, kGenericInterconnectDeviceName);
      expect(name.toLowerCase(), isNot(contains('localhost')));
    });

    test('real hardware model becomes "Hibiki · <model>"', () async {
      expect(
        await resolveInterconnectDeviceName(_FakeDeviceInfo('Pixel 7')),
        'Hibiki · Pixel 7',
      );
    });

    test('desktop hostname flows through as the device name', () async {
      expect(
        await resolveInterconnectDeviceName(_FakeDeviceInfo('DESKTOP-A1B2C3')),
        'Hibiki · DESKTOP-A1B2C3',
      );
    });

    test('null / empty model falls back to the generic label', () async {
      expect(
        await resolveInterconnectDeviceName(_FakeDeviceInfo(null)),
        kGenericInterconnectDeviceName,
      );
      expect(
        await resolveInterconnectDeviceName(_FakeDeviceInfo('   ')),
        kGenericInterconnectDeviceName,
      );
    });

    test(
        'a throwing device-info source degrades to the generic label, not a '
        'crash', () async {
      expect(
        await resolveInterconnectDeviceName(
            _FakeDeviceInfo(null, throws: true)),
        kGenericInterconnectDeviceName,
      );
    });
  });

  // Host-side defense-in-depth: even if a (foreign/old) client advertises
  // "localhost" as its name, the server must not persist it as the peer's
  // device name (TODO-1356). Exercises the real /api/pair/v2 handler.
  group('host does not store a "localhost" peer name', () {
    late Directory tempDir;
    late FushiSyncServer server;
    late List<FushiPairedPeerRegistration> registrations;

    Future<void> startServer() async {
      tempDir =
          Directory.systemTemp.createTempSync('hibiki_peer_name_guard_test');
      registrations = <FushiPairedPeerRegistration>[];
      server = FushiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: 'shared-token',
        allowLan: true,
      )
        ..onPairRequest = ((FushiPairRequest _) async => true)
        ..lanRequiresPinProvider = (() async => false)
        ..onPeerPaired = ((FushiPairedPeerRegistration reg) async {
          registrations.add(reg);
        })
        ..pairedPeerTokensProvider = (() async => const <String>{});
      await server.start();
    }

    tearDown(() async {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<String> startSession(String clientNonce,
        {required String name, String? clientDeviceId}) async {
      final http.Response resp = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, String>{
          'name': name,
          'clientNonce': clientNonce,
          if (clientDeviceId != null) 'clientDeviceId': clientDeviceId,
        }),
      );
      expect(resp.statusCode, 200);
      return (jsonDecode(resp.body) as Map<String, dynamic>)['sessionId']
          as String;
    }

    Future<void> confirm(String sessionId) async {
      final http.Response resp = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, String>{'sessionId': sessionId}),
      );
      expect(resp.statusCode, 200);
    }

    test('name "localhost" is dropped to null (not stored verbatim)', () async {
      await startServer();
      final String sid = await startSession('cn-lh',
          name: 'localhost', clientDeviceId: 'device-lh');
      await confirm(sid);

      expect(registrations, hasLength(1));
      expect(registrations.single.deviceName, isNull);
    });

    test('a real name is stored verbatim', () async {
      await startServer();
      final String sid = await startSession('cn-real',
          name: 'Galaxy S21', clientDeviceId: 'device-real');
      await confirm(sid);

      expect(registrations, hasLength(1));
      expect(registrations.single.deviceName, 'Galaxy S21');
    });
  });
}
