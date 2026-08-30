#undef NDEBUG

#include <cassert>
#include <fstream>
#include <iterator>
#include <string>

#ifndef FUSHI_RUNNER_SOURCE_DIR
#error FUSHI_RUNNER_SOURCE_DIR must identify the Windows runner source tree
#endif

namespace {

std::string FunctionSlice(const std::string &source, const char *start,
                          const char *next) {
  const size_t begin = source.find(start);
  assert(begin != std::string::npos);
  const size_t end = source.find(next, begin + 1);
  assert(end != std::string::npos);
  return source.substr(begin, end - begin);
}

} // namespace

int main() {
  std::ifstream input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                      "/low_level_mouse_hook.cpp");
  assert(input.good());
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());

  const std::string begin =
      FunctionSlice(source, "bool BeginAttachedGlyphTransaction(",
                    "bool AdvanceAttachedGlyphReleaseIfAcknowledged();");
  assert(begin.find("TryAcquireSRWLockExclusive(") != std::string::npos);
  assert(begin.find("\n  AcquireSRWLockExclusive(") == std::string::npos);
  assert(begin.find("RequestAttachedGlyphPhysicalReconciliation()") !=
         std::string::npos);

  const size_t revoked_begin =
      begin.find("if (request_seq == 0 || after_publish.get() != snapshot.get())");
  const size_t admitted_begin = begin.find(
      "if (!g_attached_active_transaction.latch.Begin", revoked_begin);
  assert(revoked_begin != std::string::npos &&
         admitted_begin != std::string::npos);
  const std::string revoked_after_publish =
      begin.substr(revoked_begin, admitted_begin - revoked_begin);
  assert(revoked_after_publish.find("latch.Cancel()") != std::string::npos);
  assert(revoked_after_publish.find("MarkPhysicalUp()") == std::string::npos);

  const size_t post_failure_begin = begin.find("if (!PostMessageW(");
  assert(post_failure_begin != std::string::npos);
  const std::string post_failure = begin.substr(post_failure_begin);
  assert(post_failure.find("latch.Cancel()") != std::string::npos);
  assert(post_failure.find("g_attached_pending_cancel_transaction_id.store") !=
         std::string::npos);
  assert(post_failure.find("MarkPhysicalUp()") == std::string::npos);
  assert(post_failure.find("g_attached_pending_up_transaction_id.store") ==
         std::string::npos);

  const std::string callback_up =
      FunctionSlice(source, "bool TryObserveAttachedGlyphPhysicalUp(",
                    "bool EndAttachedGlyphTransaction(");
  assert(callback_up.find("TryAcquireSRWLockExclusive(") != std::string::npos);
  assert(callback_up.find("\n  AcquireSRWLockExclusive(") == std::string::npos);
  assert(callback_up.find("latch.cancelled()") != std::string::npos);

  const std::string wake =
      FunctionSlice(source, "void RequestAttachedGlyphReleasePoll() {",
                    "bool ObserveAttachedGlyphPhysicalUp(");
  assert(wake.find("lock_guard") == std::string::npos);
  assert(wake.find("std::call_once(") == std::string::npos);

  const std::string hook = FunctionSlice(source, "LRESULT CALLBACK HookProc(",
                                         "void HookThreadMain()");
  assert(hook.find("HasActiveAttachedGlyphTransactionFast()") !=
         std::string::npos);
  assert(hook.find("TryObserveAttachedGlyphPhysicalUp(info->pt, false)") ==
         std::string::npos);

  const std::string release = FunctionSlice(
      source, "bool AdvanceAttachedGlyphReleaseIfAcknowledged() {",
      "LRESULT CALLBACK HookProc(");
  assert(release.find("if (!status.ok())") != std::string::npos);
  assert(release.find("FailOpenRetireAttachedGlyphTransaction") !=
         std::string::npos);
  assert(release.find("PublishLookupShieldTransaction") != std::string::npos);
  assert(release.find("status.fault_mask != 0") != std::string::npos);
  assert(release.find("kLookupShieldStatusFaulted") != std::string::npos);
  assert(release.find("kAttachedShieldAcknowledgeTimeoutMs") !=
         std::string::npos);
  assert(release.find("AttachedGlyphAcknowledgeTimedOut") !=
         std::string::npos);
  const std::string fail_open = FunctionSlice(
      source, "bool FailOpenRetireAttachedGlyphTransaction(",
      "// Device replacement or a removed hook");
  assert(fail_open.find("kLowLevelMouseAttachedGlyphAbortMessage") !=
         std::string::npos);
  const size_t revoke_snapshot =
      fail_open.find("std::atomic_compare_exchange_weak_explicit(");
  const size_t publish_inactive = fail_open.find(
      "g_attached_active_transaction_id.store(0");
  const size_t disarm_target =
      fail_open.find("g_target.compare_exchange_strong(");
  assert(revoke_snapshot != std::string::npos &&
         disarm_target != std::string::npos &&
         publish_inactive != std::string::npos &&
         revoke_snapshot < disarm_target &&
         disarm_target < publish_inactive);

  std::ifstream reader_input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                             "/voice_hook_reader.cpp");
  assert(reader_input.good());
  const std::string reader((std::istreambuf_iterator<char>(reader_input)),
                           std::istreambuf_iterator<char>());
  const std::string publish = FunctionSlice(
      reader, "uint32_t TryPublishLookupShieldRequestOnce(",
      "void ResetLookupCursorsLocked(");
  const size_t claim = publish.find("InterlockedCompareExchange(");
  const size_t ownership =
      publish.find("!AttachedGeometryProviderOwns(header)");
  const size_t payload =
      publish.find("lookup_shield_owner_kind", ownership);
  assert(claim != std::string::npos && ownership != std::string::npos &&
         payload != std::string::npos && claim < ownership &&
         ownership < payload);
  assert(publish.find("&header->lookup_shield_request_seq, current") !=
         std::string::npos);
  assert(publish.find("lock_guard") == std::string::npos);
  assert(publish.find("unique_lock") == std::string::npos);
  assert(publish.find("WaitFor") == std::string::npos);
  assert(publish.find("Sleep(") == std::string::npos);

  const std::string callback_publish = FunctionSlice(
      reader, "uint32_t VoiceHookReader::TryPublishLookupShieldTransaction(",
      "uint32_t VoiceHookReader::PublishLookupShieldTransaction(");
  assert(callback_publish.find("std::try_to_lock") != std::string::npos);
  assert(callback_publish.find("std::lock_guard") == std::string::npos);
  assert(callback_publish.find("IsWindow(") == std::string::npos);
  assert(callback_publish.find("GetWindowThreadProcessId(") ==
         std::string::npos);
  return 0;
}
