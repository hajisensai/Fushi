// galgame hook 链路的统一时基：Windows `GetTickCount64()`（毫秒，开机起算）。
//
// native 侧的文本环 `TextSlot.timestamp_ms`、语音资源事件 tick、runner 的窗口录制帧
// 都用这个时钟（见 galgame_audio_source.dart / window_capture_channel.dart）。Dart 侧
// 自己产出的台词（TyranoScript DOM 源）要参与按时间戳配对语音，就必须取同一时钟的当前值，
// 不能用 DateTime / Stopwatch。

import 'dart:ffi';
import 'dart:io';

typedef _GetTickCount64Native = Uint64 Function();
typedef _GetTickCount64Dart = int Function();

final _GetTickCount64Dart? _getTickCount64 = Platform.isWindows
    ? DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<_GetTickCount64Native, _GetTickCount64Dart>(
        'GetTickCount64',
      )
    : null;

/// `GetTickCount64()` 当前值；非 Windows 返回 0（= 无时间戳，配对按「未知时刻」处理）。
int galHookTickNowMs() => _getTickCount64?.call() ?? 0;
