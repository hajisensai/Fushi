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

/// An in-memory output that collects FFmpeg output through the "ffkit"
/// protocol. Pass the value returned by [getUrl] as an output of an FFmpeg
/// command instead of a file path, then read the produced bytes with
/// [toByteArray] once the command completes. Call [close] to release the native
/// resources it holds.
class FFmpegKitOutputBuffer {
  final String _url;

  FFmpegKitOutputBuffer._(this._url);

  /// Creates an output buffer and returns the wrapper that holds the generated
  /// protocol url. [extension] is an optional format hint (e.g. "mp4").
  /// [initialCapacity] and [maxCapacity] optionally bound the native buffer
  /// size in bytes; both must be provided together.
  static Future<FFmpegKitOutputBuffer> create(
      {String? extension, int? initialCapacity, int? maxCapacity}) async {
    final String? url = await FFmpegKitPlatform.instance
        .outputBufferCreate(extension, initialCapacity, maxCapacity);
    return FFmpegKitOutputBuffer._(url ?? "");
  }

  /// Returns the protocol url to use as an FFmpeg output.
  String getUrl() => _url;

  /// Returns the number of bytes currently held by the buffer.
  Future<int> getSize() async =>
      (await FFmpegKitPlatform.instance.outputBufferGetSize(_url)) ?? 0;

  /// Returns a copy of the bytes written by FFmpeg.
  Future<Uint8List> toByteArray() async =>
      (await FFmpegKitPlatform.instance.outputBufferToByteArray(_url)) ??
      Uint8List(0);

  /// Releases the native resources held by this buffer.
  Future<void> close() => FFmpegKitPlatform.instance.outputBufferClose(_url);
}
