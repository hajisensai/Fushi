// This probe exercises a retained libmpv handle after its owning Dart isolate
// exits. Like Flutter's hot restart driver, it kills remaining worker isolates
// through the VM service. It does not recreate a Flutter engine or video page.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:developer';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/initializer.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

Future<void> _checkpoint(String message) async {
  stdout.writeln(message);
  await stdout.flush();
}

Future<void> _stopWorkers(vm.VmService service) async {
  final String? mainId = Service.getIsolateId(Isolate.current);
  if (mainId == null) {
    throw StateError('Cannot identify the probe isolate');
  }
  final Map<String, Completer<void>> exits = <String, Completer<void>>{};
  await service.streamListen(vm.EventStreams.kIsolate);
  final StreamSubscription<vm.Event> events = service.onIsolateEvent.listen((
    vm.Event event,
  ) {
    if (event.kind == vm.EventKind.kIsolateExit) {
      final Completer<void>? exited = exits[event.isolate?.id];
      if (exited != null && !exited.isCompleted) {
        exited.complete();
      }
    }
  });
  try {
    final vm.VM machine = await service.getVM();
    for (final vm.IsolateRef isolate in machine.isolates!) {
      final String id = isolate.id!;
      if (id == mainId) {
        continue;
      }
      final Completer<void> exited = Completer<void>();
      exits[id] = exited;
      try {
        await _checkpoint('WORKER KILL $id');
        await service.kill(id);
        // A successful kill request alone is not a termination barrier. Wait
        // until the worker has left FFI and emitted its IsolateExit event.
        await exited.future;
        await _checkpoint('WORKER EXITED $id');
      } on vm.SentinelException {
        // The worker already exited between getVM and kill.
      }
    }
    await _checkpoint('WORKERS EXITED');
  } finally {
    await events.cancel();
    await service.streamCancel(vm.EventStreams.kIsolate);
  }
}

Future<void> _owner(List<Object> arguments) async {
  final SendPort ready = arguments[0] as SendPort;
  final String library = arguments[1] as String;
  final ReceivePort commands = ReceivePort();
  await _checkpoint('OWNER START / LIBRARY LOAD START');
  NativeLibrary.ensureInitialized(libmpv: library);
  final generated.MPV mpv = generated.MPV(DynamicLibrary.open(library));
  await _checkpoint('LIBRARY LOADED / CREATE START');
  final Pointer<generated.mpv_handle> handle = await Initializer(mpv).create(
    (Pointer<generated.mpv_event> event) async {},
    options: <String, String>{'vo': 'null', 'ao': 'null', 'config': 'no'},
  );
  await _checkpoint('CREATE RETURNED');
  ready.send(<Object>[handle.address, commands.sendPort]);
  await commands.first;
  await _checkpoint('DISPOSE START');
  Initializer(mpv).dispose(handle);
  await _checkpoint('DISPOSE RETURNED');
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 ||
      !<String>{'kill', 'dispose'}.contains(arguments[1])) {
    throw ArgumentError('Expected <libmpv path> <kill|dispose>');
  }
  final String mode = arguments[1];
  await _checkpoint('PROBE START $mode');
  final ServiceProtocolInfo info = await Service.controlWebServer(enable: true);
  final Uri server = info.serverUri!;
  final vm.VmService service = await vmServiceConnectUri(
    server.replace(scheme: 'ws', path: '${server.path}ws').toString(),
  );
  await _checkpoint('VM SERVICE READY');
  final ReceivePort ready = ReceivePort();
  final ReceivePort exited = ReceivePort();
  final Future<dynamic> exitNotification = exited.first;
  final Isolate owner = await Isolate.spawn<List<Object>>(_owner, <Object>[
    ready.sendPort,
    arguments[0],
  ], onExit: exited.sendPort);
  final List<Object> created = (await ready.first) as List<Object>;
  await _checkpoint('OWNER READY / $mode REQUEST START');
  final Pointer<generated.mpv_handle> handle =
      Pointer<generated.mpv_handle>.fromAddress(created[0] as int);
  if (mode == 'kill') {
    owner.kill(priority: Isolate.immediate);
  } else {
    (created[1] as SendPort).send('dispose');
  }
  await exitNotification;
  await _checkpoint('OWNER EXITED');
  await _stopWorkers(service);
  await service.dispose();

  final generated.MPV mpv = generated.MPV(DynamicLibrary.open(arguments[0]));
  // libmpv coalesces notifications while an earlier wakeup is pending. Reset
  // that state after the owner is gone so this explicitly exercises a fresh
  // wakeup, rather than accidentally passing with an already-signalled queue.
  await _checkpoint('EVENT DRAIN START');
  while (mpv.mpv_wait_event(handle, 0).ref.event_id !=
      generated.mpv_event_id.MPV_EVENT_NONE) {}
  await _checkpoint('EVENTS DRAINED / WAKEUP START');
  mpv.mpv_wakeup(handle);
  await _checkpoint('WAKEUP RETURNED / QUIT START');
  final Pointer<Utf8> quit = 'quit'.toNativeUtf8();
  try {
    final int result = mpv.mpv_command_string(handle, quit.cast());
    if (result < 0) {
      throw StateError('libmpv quit failed: $result');
    }
  } finally {
    calloc.free(quit);
  }
  await _checkpoint('QUIT RETURNED');
  await _checkpoint('PASS $mode');
  // End this disposable process after the assertions; no Flutter renderer
  // exists here, and the OS reclaims the retained native resources.
  exit(0);
}
