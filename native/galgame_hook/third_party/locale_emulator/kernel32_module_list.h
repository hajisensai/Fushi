// SPDX-License-Identifier: LGPL-3.0-or-later
// Hibiki modification to Locale Emulator Core, 2026-09-07.
// Shared by the LGPL source patch and its regression test.
#pragma once

namespace fushi_locale_emulator {

// InInitializationOrderModuleList is a circular LIST_ENTRY with a separate
// sentinel. Only real entries may be converted to LDR_MODULE: the head is part
// of PEB_LDR_DATA, whose unrelated bytes are not a BaseDllName.Buffer.
template <typename Module, typename Entry, typename ModuleFromEntry>
Module* FindKernel32Module(Entry* head, ModuleFromEntry module_from_entry) {
  if (head == nullptr) return nullptr;
  for (Entry* entry = head->Flink; entry != head; entry = entry->Flink) {
    if (entry == nullptr) return nullptr;
    Module* module = module_from_entry(entry);
    const auto* name = module->BaseDllName.Buffer;
    // Preserve upstream's KERNEL32. prefix match, but do not read beyond the
    // UNICODE_STRING length. No locale APIs may run during this early phase.
    static const wchar_t prefix[] = L"KERNEL32.";
    if (name == nullptr || module->BaseDllName.Length < 9 * sizeof(*name))
      continue;
    bool matches = true;
    for (unsigned int index = 0; index < 9; ++index) {
      auto character = name[index];
      if (character >= L'a' && character <= L'z') character -= L'a' - L'A';
      if (character != prefix[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return module;
  }
  return nullptr;
}

}  // namespace fushi_locale_emulator
