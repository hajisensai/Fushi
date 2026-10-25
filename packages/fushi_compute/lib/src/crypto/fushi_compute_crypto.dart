import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_compute/src/fushi_compute_library.dart';
import 'package:fushi_compute/src/native_scratch.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

/// `ffc_crypto_*` 的本域状态码（native/fushi_compute/src/crypto.rs）。
abstract final class FfcCryptoStatus {
  /// 未加密单元的 TS 同步字节不对：数据损坏（全零单元落在这里）或不是 M2TS，与密钥无关。
  static const int aacsClearUnitInvalid = -20;

  /// 所有 unit key 都解不出合法 TS，且还没有证据表明 key 是对的：密钥不符、不支持的保护，
  /// 或首个加密单元就坏了。
  static const int aacsNoMatchingKey = -21;

  /// 所有 unit key 都解不出合法 TS，但这个解码器此前已用这批 key 解开过加密单元，或单元里
  /// 有整扇区（2048 字节）全零：数据损坏，不是密钥问题。
  static const int aacsUnitCorrupt = -23;

  /// ECDSA 验签不通过。
  static const int p256SignatureInvalid = -22;

  /// 云同步文件混淆 / 还原时读写文件失败。
  static const int syncIoError = -30;
}

typedef _CbcEncryptC =
    Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Pointer<Uint8>, Size);
typedef _CbcEncryptDart =
    int Function(Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>, int);
typedef _SyncFileC = Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef _SyncFileDart = int Function(Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _P256PublicKeyC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _P256PublicKeyDart = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _P256SignC =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _P256SignDart =
    int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>);

typedef _AacsOpenC =
    Int32 Function(Pointer<Uint8>, Size, Pointer<Pointer<Void>>);
typedef _AacsOpenDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>);
typedef _AacsCloseC = Void Function(Pointer<Void>);
typedef _AacsDecryptC =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Size>);
typedef _AacsDecryptDart =
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Size>);
typedef _EcbDecryptC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size);
typedef _EcbDecryptDart = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _CbcPkcs7C =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Size,
      Pointer<Size>,
    );
typedef _CbcPkcs7Dart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Size>,
    );

/// fushi_compute 的加密域（AES / AACS / 云同步混淆 / P-256 ECDSA）。
///
/// 原生库是硬依赖：库或本域符号缺失时 [instance] 抛 [FushiComputeUnavailableError]，
/// 没有 Dart 回退。
/// 数据经本 isolate 一块复用的原生暂存区进出（拷入 → 原地解 → 拷出，一次 memcpy 往返，
/// 实测相对 AES 可忽略）：`TypedData.address` 零拷贝只对 `@Native` 静态绑定可用，而本包
/// 按路径动态加载。单次调用处理一个 relay 块（32 单元）或一个 HLS 分片。
///
/// 暂存区与固定槽都由 [NativeScratch] 持有：AACS relay 每次起一个短命 isolate，退出时由
/// finalizer 释放，不留下外部分配（HBK-AUDIT-004）。
final class FushiComputeCrypto implements Finalizable {
  FushiComputeCrypto._(FushiCompute lib)
    : _aacsOpen = lib.library.lookupFunction<_AacsOpenC, _AacsOpenDart>(
        'ffc_crypto_aacs_open',
      ),
      _aacsClose = NativeFinalizer(
        lib.library
            .lookup<NativeFunction<_AacsCloseC>>('ffc_crypto_aacs_close')
            .cast(),
      ),
      _aacsDecrypt = lib.library
          .lookupFunction<_AacsDecryptC, _AacsDecryptDart>(
            'ffc_crypto_aacs_decrypt_units',
            isLeaf: true,
          ),
      _ecbDecrypt = lib.library.lookupFunction<_EcbDecryptC, _EcbDecryptDart>(
        'ffc_crypto_aes128_ecb_decrypt',
        isLeaf: true,
      ),
      _cbcPkcs7 = lib.library.lookupFunction<_CbcPkcs7C, _CbcPkcs7Dart>(
        'ffc_crypto_aes_cbc_pkcs7_decrypt',
        isLeaf: true,
      ),
      _cbcEncrypt = lib.library.lookupFunction<_CbcEncryptC, _CbcEncryptDart>(
        'ffc_crypto_aes_cbc_encrypt',
        isLeaf: true,
      ),
      _syncObfuscateFile = lib.library
          .lookupFunction<_SyncFileC, _SyncFileDart>(
            'ffc_crypto_sync_obfuscate_file',
          ),
      _syncDeobfuscateFile = lib.library
          .lookupFunction<_SyncFileC, _SyncFileDart>(
            'ffc_crypto_sync_deobfuscate_file',
          ),
      _p256PublicKey = lib.library
          .lookupFunction<_P256PublicKeyC, _P256PublicKeyDart>(
            'ffc_crypto_p256_public_key',
            isLeaf: true,
          ),
      _p256Sign = lib.library.lookupFunction<_P256SignC, _P256SignDart>(
        'ffc_crypto_p256_sign_sha256',
        isLeaf: true,
      ),
      _p256Verify = lib.library.lookupFunction<_P256SignC, _P256SignDart>(
        'ffc_crypto_p256_verify_sha256',
        isLeaf: true,
      );

  final _AacsOpenDart _aacsOpen;
  final NativeFinalizer _aacsClose;
  final _AacsDecryptDart _aacsDecrypt;
  final _EcbDecryptDart _ecbDecrypt;
  final _CbcPkcs7Dart _cbcPkcs7;
  final _CbcEncryptDart _cbcEncrypt;
  final _SyncFileDart _syncObfuscateFile;
  final _SyncFileDart _syncDeobfuscateFile;
  final _P256PublicKeyDart _p256PublicKey;
  final _P256SignDart _p256Sign;
  final _P256SignDart _p256Verify;

  // 本 isolate 的原生暂存区（随 isolate 存活；调用全是同步的，不会并发复用）。
  final NativeScratch _scratch = NativeScratch();

  // 固定槽，一块定长内存按偏移切：outLen 8 / key 32 / IV 16 / P-256 私钥 32 / 公钥点 65 /
  // 签名 64 字节。
  final NativeScratch _slots = NativeScratch.fixed(_sigAt + 64);
  static const int _keyAt = 8;
  static const int _ivAt = _keyAt + 32;
  static const int _scalarAt = _ivAt + 16;
  static const int _pointAt = _scalarAt + 32;
  static const int _sigAt = _pointAt + 65;

  Pointer<Size> get _outLen => _slots.pointer.cast<Size>();
  Pointer<Uint8> get _keyBuf => _slots.pointer + _keyAt;
  Pointer<Uint8> get _ivBuf => _slots.pointer + _ivAt;
  Pointer<Uint8> get _scalarBuf => _slots.pointer + _scalarAt;
  Pointer<Uint8> get _pointBuf => _slots.pointer + _pointAt;
  Pointer<Uint8> get _sigBuf => _slots.pointer + _sigAt;

  Pointer<Uint8> _scratchFor(int length) => _scratch.reserve(length);

  static FushiComputeCrypto? _instance;

  /// 本 isolate 的加密域绑定（首次访问时 lookup）。
  static FushiComputeCrypto get instance => _instance ??= _load();

  static FushiComputeCrypto _load() {
    final FushiCompute lib = FushiCompute.require();
    try {
      return FushiComputeCrypto._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('crypto', e.message ?? e);
    }
  }

  /// AES-128 ECB 原地解 [data]（长度须为 16 的倍数）。
  void aes128EcbDecryptInPlace(Uint8List key, Uint8List data) {
    if (key.length != 16) {
      throw ArgumentError.value(key.length, 'key', 'AES-128 needs 16 bytes');
    }
    if (data.length % 16 != 0) {
      throw ArgumentError.value(data.length, 'data', 'not a multiple of 16');
    }
    if (data.isEmpty) return;
    _keyBuf.asTypedListOutOfLine(16).setAll(0, key);
    final Pointer<Uint8> buf = _scratchFor(data.length);
    final Uint8List view = buf.asTypedListOutOfLine(data.length)
      ..setAll(0, data);
    final int code = _ecbDecrypt(_keyBuf, buf, data.length);
    _keyBuf.asTypedListOutOfLine(32).fillRange(0, 32, 0);
    if (code != FfcStatus.ok) {
      throw StateError('ffc_crypto_aes128_ecb_decrypt: $code');
    }
    data.setAll(0, view);
  }

  /// AES-CBC + PKCS7 解密 [data]（key 16 / 24 / 32 字节，[iv] 16 字节）。
  ///
  /// 异常形态与原 pointycastle `PaddedBlockCipherImpl` 一致：长度不是块长整数倍、
  /// key / IV 长度非法、填充非法都抛 [ArgumentError]。
  Uint8List aesCbcPkcs7Decrypt(Uint8List data, Uint8List key, Uint8List iv) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError('Key length not 128/192/256 bits.');
    }
    if (iv.length != 16) {
      throw ArgumentError(
        'Initialization vector must be the same length as block size',
      );
    }
    // 空输入：pointycastle 在这里抛的是 RangeError（它自己的越界 bug），这里统一成
    // ArgumentError；两者对调用方都是「这个分片解不了」。
    if (data.isEmpty || data.length % 16 != 0) {
      throw ArgumentError(
        "Input data length must be a multiple of cipher's block size",
      );
    }
    _keyBuf.asTypedListOutOfLine(key.length).setAll(0, key);
    _ivBuf.asTypedListOutOfLine(16).setAll(0, iv);
    final Pointer<Uint8> buf = _scratchFor(data.length);
    final Uint8List view = buf.asTypedListOutOfLine(data.length)
      ..setAll(0, data);
    final int code = _cbcPkcs7(
      _keyBuf,
      key.length,
      _ivBuf,
      buf,
      data.length,
      _outLen,
    );
    _keyBuf.asTypedListOutOfLine(32).fillRange(0, 32, 0);
    if (code == FfcStatus.badInput) {
      throw ArgumentError('Invalid or corrupted pad block');
    }
    if (code != FfcStatus.ok) {
      throw StateError('ffc_crypto_aes_cbc_pkcs7_decrypt: $code');
    }
    return Uint8List.fromList(Uint8List.sublistView(view, 0, _outLen.value));
  }

  /// AES-CBC 加密（不填充；[data] 长度须为 16 的倍数，key 16 / 24 / 32 字节）。
  /// 生产路径只解密，这个给测试造密文。
  Uint8List aesCbcEncryptNoPadding(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
  ) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError('Key length not 128/192/256 bits.');
    }
    if (iv.length != 16 || data.length % 16 != 0) {
      throw ArgumentError('IV must be 16 bytes and data whole blocks');
    }
    if (data.isEmpty) return Uint8List(0);
    _keyBuf.asTypedListOutOfLine(key.length).setAll(0, key);
    _ivBuf.asTypedListOutOfLine(16).setAll(0, iv);
    final Pointer<Uint8> buf = _scratchFor(data.length);
    final Uint8List view = buf.asTypedListOutOfLine(data.length)
      ..setAll(0, data);
    final int code = _cbcEncrypt(_keyBuf, key.length, _ivBuf, buf, data.length);
    _keyBuf.asTypedListOutOfLine(32).fillRange(0, 32, 0);
    if (code != FfcStatus.ok) {
      throw StateError('ffc_crypto_aes_cbc_encrypt: $code');
    }
    return Uint8List.fromList(view);
  }

  /// 云同步「防扫盘」混淆整个文件：[destination] 写成 `魔数 + XOR(source)`（创建或截断，
  /// 同 `File.openWrite()`），读、XOR、写全在 Rust 里流式完成，Dart 只传路径。
  /// keystream = SHA-256("hibiki")，魔数 `HBKOBF 01 00`，都**永远不能改**。
  ///
  /// 同步阻塞调用：在后台 isolate 里跑（`Isolate.run`）。读写失败抛 [FileSystemException]。
  void syncObfuscateFile(String source, String destination) =>
      _syncFile(_syncObfuscateFile, 'obfuscate', source, destination);

  /// 还原 [syncObfuscateFile] 的产物：[source] 带魔数则去头 XOR 写到 [destination]，
  /// 不带魔数（旧明文 / 短于魔数）原样复制。其余同 [syncObfuscateFile]。
  void syncDeobfuscateFile(String source, String destination) =>
      _syncFile(_syncDeobfuscateFile, 'deobfuscate', source, destination);

  void _syncFile(
    _SyncFileDart fn,
    String op,
    String source,
    String destination,
  ) {
    final List<int> src = utf8.encode(source);
    final List<int> dst = utf8.encode(destination);
    if (src.isEmpty || dst.isEmpty) {
      throw ArgumentError('empty path');
    }
    final Pointer<Uint8> buf = malloc<Uint8>(src.length + dst.length);
    try {
      buf.asTypedListOutOfLine(src.length + dst.length)
        ..setAll(0, src)
        ..setAll(src.length, dst);
      final int code = fn(buf, src.length, buf + src.length, dst.length);
      if (code == FfcCryptoStatus.syncIoError) {
        throw FileSystemException('sync $op failed', '$source -> $destination');
      }
      if (code != FfcStatus.ok) {
        throw StateError('ffc_crypto_sync_${op}_file: $code');
      }
    } finally {
      malloc.free(buf);
    }
  }

  /// P-256 公钥：32 字节大端私钥标量 → 65 字节未压缩点 `04‖x‖y`。
  /// 长度不对或标量不在 [1, n-1] 抛 [ArgumentError]。
  Uint8List p256PublicKey(Uint8List privateKey) {
    _loadScalar(privateKey);
    final int code = _p256PublicKey(_scalarBuf, _pointBuf);
    _scalarBuf.asTypedListOutOfLine(32).fillRange(0, 32, 0);
    if (code == FfcStatus.invalidArgument) {
      throw ArgumentError.value(
        privateKey,
        'privateKey',
        'scalar out of range',
      );
    }
    if (code != FfcStatus.ok) {
      throw StateError('ffc_crypto_p256_public_key: $code');
    }
    return Uint8List.fromList(_pointBuf.asTypedListOutOfLine(65));
  }

  /// ECDSA/SHA-256 签 [message]（RFC 6979 确定性 k，不做 low-s 归一），返回 P1363
  /// `r‖s` 64 字节。
  Uint8List p256SignSha256(Uint8List privateKey, List<int> message) {
    _loadScalar(privateKey);
    final Pointer<Uint8> msg = _scratchFor(message.length);
    if (message.isNotEmpty)
      msg.asTypedListOutOfLine(message.length).setAll(0, message);
    final int code = _p256Sign(_scalarBuf, msg, message.length, _sigBuf);
    _scalarBuf.asTypedListOutOfLine(32).fillRange(0, 32, 0);
    if (code == FfcStatus.invalidArgument) {
      throw ArgumentError.value(
        privateKey,
        'privateKey',
        'scalar out of range',
      );
    }
    if (code != FfcStatus.ok) {
      throw StateError('ffc_crypto_p256_sign_sha256: $code');
    }
    return Uint8List.fromList(_sigBuf.asTypedListOutOfLine(64));
  }

  /// 用 65 字节未压缩点 [publicPoint] 验 [message] 的 P1363 签名 [signature]（64 字节）。
  /// 签名不对 / 点不在曲线上 / 长度不对都返回 false，不抛。
  bool p256VerifySha256(
    Uint8List publicPoint,
    List<int> message,
    Uint8List signature,
  ) {
    if (publicPoint.length != 65 || signature.length != 64) return false;
    _pointBuf.asTypedListOutOfLine(65).setAll(0, publicPoint);
    _sigBuf.asTypedListOutOfLine(64).setAll(0, signature);
    final Pointer<Uint8> msg = _scratchFor(message.length);
    if (message.isNotEmpty)
      msg.asTypedListOutOfLine(message.length).setAll(0, message);
    final int code = _p256Verify(_pointBuf, msg, message.length, _sigBuf);
    if (code == FfcStatus.ok) return true;
    if (code == FfcCryptoStatus.p256SignatureInvalid ||
        code == FfcStatus.badInput) {
      return false;
    }
    throw StateError('ffc_crypto_p256_verify_sha256: $code');
  }

  void _loadScalar(Uint8List privateKey) {
    if (privateKey.length != 32) {
      throw ArgumentError.value(
        privateKey.length,
        'privateKey',
        'must be 32 bytes',
      );
    }
    _scalarBuf.asTypedListOutOfLine(32).setAll(0, privateKey);
  }

  /// 建一个 AACS 内容解码器（每个 unit key 16 字节，至少一个）。
  AacsNativeDecoder openAacs(List<Uint8List> unitKeys) {
    if (unitKeys.isEmpty) {
      throw ArgumentError.value(unitKeys, 'unitKeys', 'empty');
    }
    final Uint8List packed = Uint8List(unitKeys.length * 16);
    for (int i = 0; i < unitKeys.length; i++) {
      if (unitKeys[i].length != 16) {
        throw ArgumentError.value(unitKeys[i].length, 'unitKeys[$i]');
      }
      packed.setAll(i * 16, unitKeys[i]);
    }
    final Pointer<Uint8> keys = malloc<Uint8>(packed.length);
    final Pointer<Pointer<Void>> handle = calloc<Pointer<Void>>();
    try {
      keys.asTypedListOutOfLine(packed.length).setAll(0, packed);
      final int code = _aacsOpen(keys, unitKeys.length, handle);
      if (code != FfcStatus.ok) throw StateError('ffc_crypto_aacs_open: $code');
      return AacsNativeDecoder._(this, handle.value);
    } finally {
      keys.asTypedListOutOfLine(packed.length).fillRange(0, packed.length, 0);
      packed.fillRange(0, packed.length, 0);
      malloc.free(keys);
      calloc.free(handle);
    }
  }
}

/// [AacsNativeDecoder.decryptUnits] 的结果。
final class AacsUnitsResult {
  const AacsUnitsResult(this.status, this.unitsDone);

  /// [FfcStatus.ok] 或 [FfcCryptoStatus] 的错误码。
  final int status;

  /// 成功解完的单元数；失败时等于失败单元的下标（该单元及其后保持原样）。
  final int unitsDone;

  bool get ok => status == FfcStatus.ok;
}

/// 原生侧持有 unit key 与「上次命中的 key」的 AACS 解码器。随 Dart 对象回收释放。
final class AacsNativeDecoder implements Finalizable {
  AacsNativeDecoder._(this._crypto, this._handle) {
    _crypto._aacsClose.attach(this, _handle, detach: this);
  }

  final FushiComputeCrypto _crypto;
  final Pointer<Void> _handle;

  /// 「解完单元数」输出槽。
  final NativeScratch _done = NativeScratch.fixed(8);

  /// 单元长度。
  static const int unitLength = 6144;

  /// 原地解 [units]（长度须为 6144 的正整数倍），一次 FFI 调用处理全部单元。
  AacsUnitsResult decryptUnits(Uint8List units) {
    if (units.isEmpty || units.length % unitLength != 0) {
      throw ArgumentError.value(units.length, 'units', 'not whole AACS units');
    }
    final Pointer<Uint8> buf = _crypto._scratchFor(units.length);
    final Uint8List view = buf.asTypedListOutOfLine(units.length)
      ..setAll(0, units);
    final Pointer<Size> doneOut = _done.pointer.cast<Size>();
    final int code = _crypto._aacsDecrypt(_handle, buf, units.length, doneOut);
    if (code != FfcStatus.ok &&
        code != FfcCryptoStatus.aacsClearUnitInvalid &&
        code != FfcCryptoStatus.aacsNoMatchingKey &&
        code != FfcCryptoStatus.aacsUnitCorrupt) {
      throw StateError('ffc_crypto_aacs_decrypt_units: $code');
    }
    final int done = doneOut.value;
    // 只拷回成功的单元：失败单元及其后保持调用方原样。
    if (done > 0) units.setRange(0, done * unitLength, view);
    return AacsUnitsResult(code, done);
  }
}
