// SPDX-License-Identifier: LGPL-3.0-or-later
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../third_party/locale_emulator/kernel32_module_list.h"

#include <windows.h>

#include <cassert>
#include <cstddef>
#include <cstdio>

namespace {

struct Name {
  USHORT Length;
  USHORT MaximumLength;
  const wchar_t* Buffer;
};

// Keep the x86 LDR_MODULE offsets used in the actual crash: initialization
// links at +0x10 and BaseDllName.Buffer at +0x30.
struct Module {
  LIST_ENTRY load_links;
  LIST_ENTRY memory_links;
  LIST_ENTRY init_links;
  void* image_base;
  void* entry_point;
  ULONG image_size;
  Name FullDllName;
  Name BaseDllName;
};
static_assert(sizeof(void*) == 4, "This regression targets Windows x86 LE");
static_assert(offsetof(Module, init_links) == 0x10, "LDR_MODULE link ABI");
static_assert(offsetof(Module, BaseDllName) + offsetof(Name, Buffer) == 0x30,
              "LDR_MODULE name ABI");

void SetName(Module* module, const wchar_t* name, USHORT length) {
  module->BaseDllName = {length, length, name};
}

Module* Find(LIST_ENTRY* head, unsigned int* inspected) {
  return fushi_locale_emulator::FindKernel32Module<Module>(
      head, [head, inspected](LIST_ENTRY* entry) {
        assert(entry != head);  // The regression: never inspect the sentinel.
        ++*inspected;
        return reinterpret_cast<Module*>(
            reinterpret_cast<unsigned char*>(entry) -
            offsetof(Module, init_links));
      });
}

void Link(LIST_ENTRY* left, LIST_ENTRY* right) {
  left->Flink = right;
  right->Blink = left;
}

void TestEmptyList() {
  LIST_ENTRY head{};
  Link(&head, &head);
  unsigned int inspected = 0;
  assert(Find(&head, &inspected) == nullptr);
  assert(inspected == 0);
}

void TestOnlyNtdllWithUnreadableSentinelName() {
  // Back the list head with an intentionally misleading pseudo-module name,
  // exactly the old loop's failure shape. The production helper must not
  // convert/read this sentinel, even though its apparent Buffer is 0x1000.
  Module sentinel{};
  SetName(&sentinel, reinterpret_cast<const wchar_t*>(0x1000), 24);
  LIST_ENTRY* head = &sentinel.init_links;
  Module ntdll{};
  SetName(&ntdll, L"ntdll.dll", 18);
  Link(head, &ntdll.init_links);
  Link(&ntdll.init_links, head);
  unsigned int inspected = 0;
  assert(Find(head, &inspected) == nullptr);
  assert(inspected == 1);
}

void TestKernel32FirstAndAfterNtdll() {
  for (int with_ntdll = 0; with_ntdll != 2; ++with_ntdll) {
    LIST_ENTRY head{};
    Module ntdll{}, kernel32{};
    SetName(&ntdll, L"ntdll.dll", 18);
    SetName(&kernel32, L"KeRnEl32.dll", 24);
    if (with_ntdll) {
      Link(&head, &ntdll.init_links);
      Link(&ntdll.init_links, &kernel32.init_links);
    } else {
      Link(&head, &kernel32.init_links);
    }
    Link(&kernel32.init_links, &head);
    unsigned int inspected = 0;
    assert(Find(&head, &inspected) == &kernel32);
    assert(inspected == (with_ntdll ? 2u : 1u));
  }
}

void TestAbsentKernel32SkipsShortAndNullNames() {
  LIST_ENTRY head{};
  Module short_name{}, null_name{}, other{};
  SetName(&short_name, reinterpret_cast<const wchar_t*>(0x1000), 2);
  SetName(&null_name, nullptr, 24);
  SetName(&other, L"kernelbase.dll", 28);
  Link(&head, &short_name.init_links);
  Link(&short_name.init_links, &null_name.init_links);
  Link(&null_name.init_links, &other.init_links);
  Link(&other.init_links, &head);
  unsigned int inspected = 0;
  assert(Find(&head, &inspected) == nullptr);
  assert(inspected == 3);
}

}  // namespace

int main() {
  TestEmptyList();
  TestOnlyNtdllWithUnreadableSentinelName();
  TestKernel32FirstAndAfterNtdll();
  TestAbsentKernel32SkipsShortAndNullNames();
  std::puts("4 Locale Emulator module-list tests passed");
}
