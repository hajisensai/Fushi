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

/// A streaming input that feeds bytes to FFmpeg incrementally through the
/// "ffkit" protocol. Pass the value returned by [getUrl] as an input of an
/// FFmpeg command, push data with [write] while the command runs, then signal
/// the end of the input with [closeInput]. Call [close] to release the native
/// resources it holds.
class FFmpegKitStreamInput {
  final String _url;

  FFmpegKitStreamInput._(this._url);

  /// Creates a stream input and returns the wrapper that holds the generated
  /// protocol url. [extension] is an optional format hint (e.g. "mp4").
  /// [capacity] optionally sets the native ring-buffer capacity in bytes.
  static Future<FFmpegKitStreamInput> create(
      {String? extension, int? capacity}) async {
    final String? url =
        await FFmpegKitPlatform.instance.streamInputCreate(extension, capacity);
    return FFmpegKitStreamInput._(url ?? "");
  }

  /// Returns the protocol url to use as an FFmpeg input.
  String getUrl() => _url;

  /// Writes [data] to the stream, blocking up to [timeoutMs] milliseconds when
  /// the native buffer is full. Returns the number of bytes accepted.
  Future<int> write(Uint8List data, {int? timeoutMs}) async =>
      (await FFmpegKitPlatform.instance.streamInputWrite(_url, data, timeoutMs)) ??
      0;

  /// Signals that no more data will be written, letting FFmpeg reach
  /// end-of-input.
  Future<void> closeInput() =>
      FFmpegKitPlatform.instance.streamInputCloseInput(_url);

  /// Releases the native resources held by this stream.
  Future<void> close() => FFmpegKitPlatform.instance.streamInputClose(_url);
}
