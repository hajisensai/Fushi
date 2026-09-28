import 'dart:io';

import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_locator.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 本机「Anki 同步客户端」数据目录名（`<support>/anki_sync`，跟着用户可配的数据根走）。
const String kAnkiSyncDirName = 'anki_sync';

bool _resolved = false;
AnkiSyncSession? _session;

/// 全 app 唯一的同步客户端会话（一个 helper 进程、一个本地库、一份日志）。
/// 本机找不到 `fushi-anki-sync`（移动端、没带 helper 的安装包）时为 null——
/// 设置页据此不显示这个后端。
AnkiSyncSession? get sharedAnkiSyncSession {
  if (_resolved) return _session;
  _resolved = true;
  final String? exe = resolveFushiAnkiSyncExecutable();
  if (exe == null) return null;
  return _session = AnkiSyncSession(
    root: () async => Directory(
      p.join((await AppPaths.supportRootDirectory()).path, kAnkiSyncDirName),
    ),
    startClient: () => FushiAnkiSyncClient.start(exe),
  );
}
