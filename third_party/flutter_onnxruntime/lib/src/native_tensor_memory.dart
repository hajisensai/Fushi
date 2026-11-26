// Fushi fork (PATCHES.md delta 19, BUG-5508).
//
// Process memory that carries tensor data across the plugin boundary as an
// address. `dart:ffi` exists everywhere but web; the web plugin never reports
// `supportsNativeTensorMemory`, so it gets a stub that is never reached.
export 'native_tensor_memory_stub.dart' if (dart.library.ffi) 'native_tensor_memory_ffi.dart';
