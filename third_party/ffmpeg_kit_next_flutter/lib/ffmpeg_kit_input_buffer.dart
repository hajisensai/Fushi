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

/// An in-memory input that exposes a byte array to FFmpeg through the "ffkit"
/// protocol. Pass the value returned by [getUrl] as an input of an FFmpeg
/// command instead of a file path. Call [close] when the buffer is no longer
/// needed to release the native resources it holds.
class FFmpegKitInputBuffer {
  final String _url;
  final int _size;

  FFmpegKitInputBuffer._(this._url, this._size);

  /// Registers [data] as an input buffer and returns the wrapper that holds the
  /// generated protocol url. [extension] is an optional hint (e.g. "mp4") that
  /// helps FFmpeg detect the input format.
  static Future<FFmpegKitInputBuffer> fromByteArray(Uint8List data,
      [String? extension]) async {
    final String? url = await FFmpegKitPlatform.instance
        .inputBufferFromByteArray(data, extension);
    return FFmpegKitInputBuffer._(url ?? "", data.length);
  }

  /// Returns the protocol url to use as an FFmpeg input.
  String getUrl() => _url;

  /// Returns the size of the buffer in bytes.
  int getSize() => _size;

  /// Releases the native resources held by this buffer.
  Future<void> close() => FFmpegKitPlatform.instance.inputBufferClose(_url);
}
