#ifndef RUNNER_NATIVE_GLOG_H_
#define RUNNER_NATIVE_GLOG_H_

#include <string>

// Appends one timestamped "[native]" line to <systemTemp>/hibiki_glookup.log,
// the same file the Dart lookup log writes. Best-effort: never throws.
void NativeGlog(const std::string& message);

#endif  // RUNNER_NATIVE_GLOG_H_
