/*
 * Copyright (c) 2026 Taner Sener
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import 'dart:typed_data';

import 'package:ffmpeg_kit_next_flutter_platform_interface/ffmpeg_kit_flutter_platform_interface.dart';

/// A streaming output that pulls bytes from FFmpeg incrementally through the
/// "ffkit" protocol. Pass the value returned by [getUrl] as an output of an
/// FFmpeg command, then consume the produced data with [read] while the command
/// runs. Call [close] to release the native resources it holds.
class FFmpegKitStreamOutput {
  final String _url;

  FFmpegKitStreamOutput._(this._url);

  /// Creates a stream output and returns the wrapper that holds the generated
  /// protocol url. [extension] is an optional format hint (e.g. "mp4").
  /// [capacity] optionally sets the native ring-buffer capacity in bytes.
  static Future<FFmpegKitStreamOutput> create(
      {String? extension, int? capacity}) async {
    final String? url = await FFmpegKitPlatform.instance
        .streamOutputCreate(extension, capacity);
    return FFmpegKitStreamOutput._(url ?? "");
  }

  /// Returns the protocol url to use as an FFmpeg output.
  String getUrl() => _url;

  /// Reads up to [maxBytes] bytes produced by FFmpeg, blocking up to
  /// [timeoutMs] milliseconds when no data is available yet. Returns an empty
  /// list when the output has ended.
  Future<Uint8List> read(int maxBytes, {int? timeoutMs}) async =>
      (await FFmpegKitPlatform.instance
          .streamOutputRead(_url, maxBytes, timeoutMs)) ??
      Uint8List(0);

  /// Releases the native resources held by this stream.
  Future<void> close() => FFmpegKitPlatform.instance.streamOutputClose(_url);
}
