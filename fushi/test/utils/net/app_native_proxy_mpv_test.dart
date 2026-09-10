import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// Optional real native-library probe. No user player is touched; a separate
/// Python process loads the specified library with null audio/video outputs.
void main() {
  test(
    'installed libmpv loads media through the authenticated app relay',
    () async {
      final String Function() oldMode = appUserProxyModeReader;
      final String Function() oldProxy = appUserProxyReader;
      addTearDown(() {
        appUserProxyModeReader = oldMode;
        appUserProxyReader = oldProxy;
      });
      final HttpServer originProxy = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => originProxy.close(force: true));
      int requests = 0;
      final Uint8List wav = Uint8List(16044);
      final ByteData header = ByteData.sublistView(wav);
      wav.setRange(0, 4, 'RIFF'.codeUnits);
      header.setUint32(4, wav.length - 8, Endian.little);
      wav.setRange(8, 16, 'WAVEfmt '.codeUnits);
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, 16000, Endian.little);
      header.setUint32(28, 32000, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      wav.setRange(36, 40, 'data'.codeUnits);
      header.setUint32(40, wav.length - 44, Endian.little);
      originProxy.listen((HttpRequest request) async {
        requests++;
        expect(request.requestedUri.host, 'native-source.invalid');
        expect(
          request.headers.value(HttpHeaders.proxyAuthorizationHeader),
          isNull,
        );
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.contentLength = wav.length;
        request.response.add(wav);
        await request.response.close();
      });
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:${originProxy.port}';
      final AppNativeProxy relay = await AppNativeProxy.start();
      addTearDown(relay.close);
      final ProcessResult result = await Process.run(
        'python',
        <String>['-c', _probe],
        environment: <String, String>{
          'FUSHI_PROBE_PROXY': relay.endpoint.toString(),
        },
      );
      expect(
        result.exitCode,
        0,
        reason: 'libmpv did not report FILE_LOADED: ${result.stdout}',
      );
      expect(requests, greaterThan(0));
    },
    skip: Platform.environment['FUSHI_TEST_MPV_DLL'] == null,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}

const String _probe = r'''
import ctypes as c, os, time
m = c.CDLL(os.environ['FUSHI_TEST_MPV_DLL'])
m.mpv_create.restype = c.c_void_p
m.mpv_initialize.argtypes = [c.c_void_p]
m.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
m.mpv_set_property_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
m.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
m.mpv_terminate_destroy.argtypes = [c.c_void_p]
class Event(c.Structure):
    _fields_ = [('event_id', c.c_int), ('error', c.c_int), ('reply_userdata', c.c_uint64), ('data', c.c_void_p)]
m.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
m.mpv_wait_event.restype = c.POINTER(Event)
h = m.mpv_create()
try:
    for k,v in [('ao','null'), ('vo','null'), ('terminal','no'), ('msg-level','all=no')]:
        assert m.mpv_set_option_string(h, k.encode(), v.encode()) >= 0
    assert m.mpv_initialize(h) >= 0
    assert m.mpv_set_property_string(h, b'http-proxy', os.environ['FUSHI_PROBE_PROXY'].encode()) >= 0
    args = (c.c_char_p * 3)(b'loadfile', b'http://native-source.invalid/probe.wav', None)
    assert m.mpv_command(h, args) >= 0
    loaded = False
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        e = m.mpv_wait_event(h, .25).contents
        if e.event_id == 8:
            loaded = True
            break
        if e.event_id == 7:
            break
    print('FILE_LOADED' if loaded else 'LOAD_FAILED')
    assert loaded
finally:
    m.mpv_terminate_destroy(h)
''';
