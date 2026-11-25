#pragma once

// EntisGLS (Entis "Cotopha" engine, ECSSakura2 VM) message text lane: pure,
// unit-tested half.
//
// Engine facts (x86 MSVC; read from the code of one Steam-release executable,
// the sample only, never an identity input):
//   * The executable exports the engine runtime by its MSVC-mangled names:
//     the Sakura2 VM's syscall table (ECSSakura2Processor::entrySysCall) and
//     the runtime classes of the message window (SakuraGL::SGLSpriteMessage)
//     and of its script binding (Rosetta::RSMessageSpriteClass).  Those
//     exports are the identity.
//   * Scripts run on the Sakura2 VM.  The message window is a native class
//     the VM reaches through the Rosetta binding: each script method is
//     registered by one call whose pushes are
//       push FLAGS(imm8); push ecx; push HANDLER; push ecx; push SIGNATURE;
//       push RETURN-TYPE (or push 0); push NAME; ...; call REGISTER
//     with NAME/SIGNATURE/RETURN-TYPE UTF-16 string literals.
//   * The handlers of `addMessageText` and `addMessageXML` both obtain the
//     native message sprite through one getter (mov edx,[ebp+10h];
//     mov ecx,[ebp+8]; call GETTER) and hand the message to the sprite.  The
//     text handler wraps the string in a text XML node and calls
//     SGLSpriteMessage::AddMessage(node) directly; the XML handler calls a
//     parse-then-add method that itself calls the same AddMessage.  That one
//     function receives every message the VM gives the window.
//   * `clearMessage`'s handler calls SGLSpriteMessage::ClearMessage() (the
//     page is wiped) through the same getter.
//   * An XML node: type at +0x0c (0 document, 1 element, 2 text), tag name
//     string at +0x10, text string at +0x28, child pointer array at +0x50
//     with its count at +0x54.  A string is {wchar_t* chars; int32 length;
//     ...}.  AddMessage reads the type (cmp [esi+0Ch],0) and the children
//     (+0x50/+0x54) and ends by calling the layout PROCESS(node), which
//     compares the tag (+0x10) with "ruby" and lays out a text node's
//     string (+0x28) under `cmp eax,2`.  A <ruby> element's reading is an
//     attribute: its children are the base text.
//
// Site resolution is structural (exports, string literals, registration
// shape, call targets and the field accesses above).  No hash, file name or
// title is consulted; anything missing or ambiguous installs nothing.

#include <windows.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <string>
#include <vector>

namespace fushi_voice_hook::entisgls {

inline constexpr char kExportSysCall[] =
    "?entrySysCall@ECSSakura2Processor@@3PAUSYSCALL_ENTRY@1@A";
inline constexpr char kExportSpriteMessage[] =
    "?m_RuntimeClass@SGLSpriteMessage@SakuraGL@@2UESLRuntimeClass@@B";
inline constexpr char kExportRosettaMessage[] =
    "?m_RuntimeClass@RSMessageSpriteClass@Rosetta@@2UESLRuntimeClass@@B";

inline constexpr wchar_t kNameAddText[] = L"addMessageText";
inline constexpr wchar_t kNameAddXml[] = L"addMessageXML";
inline constexpr wchar_t kNameClear[] = L"clearMessage";
inline constexpr wchar_t kTagRuby[] = L"ruby";

// Node layout the resolver proves (see ResolveSites).
inline constexpr uint32_t kNodeType = 0x0cu;
inline constexpr uint32_t kNodeTag = 0x10u;
inline constexpr uint32_t kNodeText = 0x28u;
inline constexpr uint32_t kNodeChildren = 0x50u;
inline constexpr uint32_t kNodeChildCount = 0x54u;
inline constexpr uint32_t kNodeTypeDocument = 0u;
inline constexpr uint32_t kNodeTypeElement = 1u;
inline constexpr uint32_t kNodeTypeText = 2u;

// Bounds of one message copy (game thread).
inline constexpr uint32_t kMaxMessageUnits = 960u;
inline constexpr uint32_t kMaxNodes = 512u;
inline constexpr uint32_t kMaxDepth = 16u;
inline constexpr uint32_t kMaxChildren = 256u;
inline constexpr uint32_t kMaxTextNodeUnits = 4096u;

// How far the resolver looks inside each function.
inline constexpr uint32_t kHandlerWindow = 0x140u;
inline constexpr uint32_t kGetterWindow = 0x30u;
inline constexpr uint32_t kAddHeadWindow = 0x90u;
inline constexpr uint32_t kAddTailWindow = 0x200u;
inline constexpr uint32_t kXmlWindow = 0x100u;
inline constexpr uint32_t kProcessWindow = 0x2000u;
inline constexpr uint32_t kTextNodeWindow = 0x60u;

// ── image view ─────────────────────────────────────────────────────────────

// A PE32 image laid out by section: bytes at RVA 0.., absolute operands are
// relative to `va_base` (the preferred base of the file the bytes came from).
struct ImageView {
  const uint8_t* bytes = nullptr;
  size_t size = 0u;
  uint32_t va_base = 0u;
  uint32_t export_rva = 0u;
  uint32_t export_size = 0u;
  struct Range {
    uint32_t begin = 0u;
    uint32_t end = 0u;
  };
  std::array<Range, 8> code{};
  size_t code_count = 0u;
};

inline uint8_t U8(const ImageView& image, uint32_t rva) {
  return rva < image.size ? image.bytes[rva] : 0u;
}

inline uint32_t U32(const ImageView& image, uint32_t rva) {
  if (rva > image.size || image.size - rva < 4u) return 0u;
  uint32_t v = 0u;
  std::memcpy(&v, image.bytes + rva, 4u);
  return v;
}

inline bool InCode(const ImageView& image, uint32_t rva, uint32_t bytes) {
  for (size_t i = 0u; i < image.code_count; ++i) {
    const auto& r = image.code[i];
    if (rva >= r.begin && rva <= r.end && bytes <= r.end - rva) return true;
  }
  return false;
}

inline bool Match(const ImageView& image, uint32_t rva,
                  std::initializer_list<uint8_t> bytes) {
  if (rva > image.size || image.size - rva < bytes.size()) return false;
  uint32_t i = 0u;
  for (const uint8_t b : bytes) {
    if (image.bytes[rva + i] != b) return false;
    ++i;
  }
  return true;
}

// Rel32 call at `rva` (E8) and its target RVA (inside code).
inline bool CallTarget(const ImageView& image, uint32_t rva, uint32_t* target) {
  if (!InCode(image, rva, 5u) || U8(image, rva) != 0xe8u) return false;
  const int64_t t = static_cast<int64_t>(rva) + 5 +
                    static_cast<int32_t>(U32(image, rva + 1u));
  if (t < 0 || t >= static_cast<int64_t>(image.size) ||
      !InCode(image, static_cast<uint32_t>(t), 1u)) {
    return false;
  }
  *target = static_cast<uint32_t>(t);
  return true;
}

// An absolute operand (VA under the file's preferred base) as an RVA.
inline bool VaToRva(const ImageView& image, uint32_t va, uint32_t* rva) {
  if (va < image.va_base || va - image.va_base >= image.size) return false;
  *rva = va - image.va_base;
  return true;
}

// Exact-name export lookup; 0 when absent, ambiguous or forwarded.
inline uint32_t FindExport(const ImageView& image, const char* name) {
  if (image.export_rva == 0u ||
      image.export_size < sizeof(IMAGE_EXPORT_DIRECTORY) ||
      image.export_rva > image.size ||
      image.size - image.export_rva < sizeof(IMAGE_EXPORT_DIRECTORY)) {
    return 0u;
  }
  IMAGE_EXPORT_DIRECTORY dir = {};
  std::memcpy(&dir, image.bytes + image.export_rva, sizeof(dir));
  if (dir.NumberOfNames > 65536u || dir.NumberOfFunctions > 65536u) return 0u;
  const size_t name_len = std::strlen(name);
  uint32_t found = 0u;
  uint32_t count = 0u;
  for (uint32_t i = 0u; i < dir.NumberOfNames; ++i) {
    const uint32_t name_rva = U32(image, dir.AddressOfNames + i * 4u);
    if (name_rva == 0u || name_rva > image.size ||
        image.size - name_rva < name_len + 1u ||
        std::memcmp(image.bytes + name_rva, name, name_len + 1u) != 0) {
      continue;
    }
    if (dir.AddressOfNameOrdinals + i * 2u + 2u > image.size) return 0u;
    uint16_t ordinal = 0u;
    std::memcpy(&ordinal, image.bytes + dir.AddressOfNameOrdinals + i * 2u, 2u);
    if (ordinal >= dir.NumberOfFunctions) return 0u;
    const uint32_t entry = U32(image, dir.AddressOfFunctions + ordinal * 4u);
    if (entry >= image.export_rva &&
        entry < image.export_rva + image.export_size) {
      return 0u;  // forwarded
    }
    found = entry;
    ++count;
  }
  return count == 1u && found != 0u && found < image.size ? found : 0u;
}

// The three runtime exports that make an image EntisGLS.
inline bool HasEntisExports(const ImageView& image) {
  return FindExport(image, kExportSysCall) != 0u &&
         FindExport(image, kExportSpriteMessage) != 0u &&
         FindExport(image, kExportRosettaMessage) != 0u;
}

// True when the UTF-16 NUL-terminated string at `rva` is exactly `text`.
inline bool WideStringAt(const ImageView& image, uint32_t rva,
                         const wchar_t* text) {
  const size_t units = std::wcslen(text);
  const size_t bytes = (units + 1u) * 2u;
  if (rva > image.size || image.size - rva < bytes) return false;
  for (size_t i = 0u; i <= units; ++i) {
    const uint16_t unit = static_cast<uint16_t>(
        image.bytes[rva + i * 2u] | (image.bytes[rva + i * 2u + 1u] << 8));
    if (unit != static_cast<uint16_t>(i < units ? text[i] : 0)) return false;
  }
  return true;
}

// Every `push imm32` in code whose operand is the VA of the UTF-16 literal
// `text`.  The literal is identified by its content at the operand, so a
// longer string that merely contains `text` never matches.
inline std::vector<uint32_t> FindStringPushes(const ImageView& image,
                                              const wchar_t* text,
                                              size_t limit) {
  std::vector<uint32_t> out;
  for (size_t c = 0u; c < image.code_count; ++c) {
    const auto& range = image.code[c];
    for (uint32_t rva = range.begin; rva + 5u <= range.end; ++rva) {
      if (image.bytes[rva] != 0x68u) continue;
      uint32_t target = 0u;
      if (!VaToRva(image, U32(image, rva + 1u), &target)) continue;
      if (InCode(image, target, 2u)) continue;
      if (!WideStringAt(image, target, text)) continue;
      out.push_back(rva);
      if (out.size() > limit) return out;
    }
  }
  return out;
}

// The handler of a Rosetta method registration whose NAME push is at
// `name_push` (see the engine facts for the push order).
inline bool RegistrationHandler(const ImageView& image, uint32_t name_push,
                                uint32_t* handler) {
  // The return type is `push 0` (6A 00) or `push imm32`.
  for (const uint32_t ret_len : {2u, 5u}) {
    if (name_push < ret_len + 16u) continue;
    const uint32_t ret = name_push - ret_len;
    if (ret_len == 2u ? !Match(image, ret, {0x6a, 0x00})
                      : U8(image, ret) != 0x68u) {
      continue;
    }
    const uint32_t sig = ret - 5u;
    const uint32_t ecx1 = sig - 1u;
    const uint32_t push_handler = ecx1 - 5u;
    const uint32_t ecx2 = push_handler - 1u;
    const uint32_t flags = ecx2 - 2u;
    if (U8(image, sig) != 0x68u || U8(image, ecx1) != 0x51u ||
        U8(image, push_handler) != 0x68u || U8(image, ecx2) != 0x51u ||
        U8(image, flags) != 0x6au || !InCode(image, flags, 16u + ret_len)) {
      continue;
    }
    uint32_t target = 0u;
    if (!VaToRva(image, U32(image, push_handler + 1u), &target) ||
        !InCode(image, target, 16u)) {
      continue;
    }
    *handler = target;
    return true;
  }
  return false;
}

// The unique registered handler of the Rosetta method `name`.
inline bool UniqueHandler(const ImageView& image, const wchar_t* name,
                          uint32_t* handler) {
  const std::vector<uint32_t> pushes = FindStringPushes(image, name, 8u);
  uint32_t found = 0u;
  uint32_t count = 0u;
  for (const uint32_t push : pushes) {
    uint32_t h = 0u;
    if (!RegistrationHandler(image, push, &h)) continue;
    if (count != 0u && h == found) continue;
    found = h;
    ++count;
  }
  if (count != 1u) return false;
  *handler = found;
  return true;
}

// A handler's object getter: `mov edx,[ebp+10h]; mov ecx,[ebp+8];
// call GETTER` near its entry.  Returns the getter and the offset after the
// call.
inline bool HandlerGetter(const ImageView& image, uint32_t handler,
                          uint32_t* getter, uint32_t* after) {
  for (uint32_t at = handler; at < handler + kHandlerWindow; ++at) {
    if (!Match(image, at, {0x8b, 0x55, 0x10, 0x8b, 0x4d, 0x08})) continue;
    uint32_t target = 0u;
    if (!CallTarget(image, at + 6u, &target)) return false;
    *getter = target;
    *after = at + 11u;
    return true;
  }
  return false;
}

// After the getter call: the register that keeps the sprite (`mov r,eax`
// right after the call, or eax itself when the next use is `mov ecx,eax`),
// then the first `mov ecx,r; call T` within the handler.  T is the method.
inline bool HandlerMethodCall(const ImageView& image, uint32_t after,
                              uint32_t* method) {
  uint8_t reg = 0u;  // eax
  if (U8(image, after) == 0x8bu && (U8(image, after + 1u) >> 6) == 3u &&
      (U8(image, after + 1u) & 7u) == 0u) {
    reg = static_cast<uint8_t>((U8(image, after + 1u) >> 3) & 7u);
    if (reg == 1u || reg == 4u || reg == 5u) return false;  // ecx/esp/ebp
  }
  const uint8_t mov_ecx = static_cast<uint8_t>(0xc8u | reg);  // 8B C8+r
  for (uint32_t at = after; at < after + kHandlerWindow; ++at) {
    if (U8(image, at) != 0x8bu || U8(image, at + 1u) != mov_ecx) continue;
    uint32_t target = 0u;
    if (!CallTarget(image, at + 2u, &target)) continue;
    *method = target;
    return true;
  }
  return false;
}

// Inside a thiscall method that keeps `this` in esi (`mov esi,ecx` near the
// entry): the first `mov ecx,esi; call T`.
inline bool FirstSelfCall(const ImageView& image, uint32_t method,
                          uint32_t window, uint32_t* target) {
  uint32_t at = method;
  for (; at < method + 0x40u; ++at) {
    if (Match(image, at, {0x8b, 0xf1})) break;
  }
  if (at >= method + 0x40u) return false;
  for (; at < method + window; ++at) {
    if (!Match(image, at, {0x8b, 0xce})) continue;
    if (CallTarget(image, at + 2u, target)) return true;
  }
  return false;
}

inline bool ContainsBytes(const ImageView& image, uint32_t begin,
                          uint32_t window,
                          std::initializer_list<uint8_t> bytes,
                          uint32_t* found = nullptr) {
  for (uint32_t at = begin; at < begin + window; ++at) {
    if (!Match(image, at, bytes)) continue;
    if (found != nullptr) *found = at;
    return true;
  }
  return false;
}

enum class SiteResult : uint32_t {
  kResolved = 0u,
  kNoExports = 1u,
  kNoRegistration = 2u,
  kNoGetter = 3u,
  kGetterMismatch = 4u,
  kNoMethod = 5u,
  kAddMismatch = 6u,
  kAddShape = 7u,
  kProcessShape = 8u,
};

struct Sites {
  uint32_t add_message = 0u;    // SGLSpriteMessage::AddMessage(node)
  uint32_t clear_message = 0u;  // SGLSpriteMessage::ClearMessage()
  uint32_t process = 0u;        // the layout AddMessage ends with
  uint32_t getter = 0u;
  uint32_t text_handler = 0u;
  uint32_t xml_handler = 0u;
  uint32_t clear_handler = 0u;
};

// Resolves AddMessage and ClearMessage, or explains why not.
inline SiteResult ResolveSites(const ImageView& image, Sites* out) {
  if (!HasEntisExports(image)) return SiteResult::kNoExports;
  Sites s;
  if (!UniqueHandler(image, kNameAddText, &s.text_handler) ||
      !UniqueHandler(image, kNameAddXml, &s.xml_handler) ||
      !UniqueHandler(image, kNameClear, &s.clear_handler)) {
    return SiteResult::kNoRegistration;
  }
  uint32_t g_text = 0u, g_xml = 0u, g_clear = 0u;
  uint32_t a_text = 0u, a_xml = 0u, a_clear = 0u;
  if (!HandlerGetter(image, s.text_handler, &g_text, &a_text) ||
      !HandlerGetter(image, s.xml_handler, &g_xml, &a_xml) ||
      !HandlerGetter(image, s.clear_handler, &g_clear, &a_clear)) {
    return SiteResult::kNoGetter;
  }
  if (g_text != g_xml || g_text != g_clear) return SiteResult::kGetterMismatch;
  s.getter = g_text;
  uint32_t xml_method = 0u;
  if (!HandlerMethodCall(image, a_text, &s.add_message) ||
      !HandlerMethodCall(image, a_xml, &xml_method) ||
      !HandlerMethodCall(image, a_clear, &s.clear_message)) {
    return SiteResult::kNoMethod;
  }
  // The XML path parses, then adds through the same AddMessage.
  uint32_t xml_add = 0u;
  if (!FirstSelfCall(image, xml_method, kXmlWindow, &xml_add) ||
      xml_add != s.add_message || s.clear_message == s.add_message) {
    return SiteResult::kAddMismatch;
  }
  // AddMessage reads the node type and its children, then lays the node
  // out: `cmp dword [esi+0Ch],0`, `mov eax,[esi+54h]`, `mov eax,[esi+50h]`
  // and a closing `push dword [ebp+8]; mov ecx,ebx; call PROCESS`.
  const uint32_t a = s.add_message;
  if (!ContainsBytes(image, a, kAddHeadWindow,
                     {0x83, 0x7e, static_cast<uint8_t>(kNodeType), 0x00}) ||
      !ContainsBytes(image, a, kAddHeadWindow,
                     {0x8b, 0x46, static_cast<uint8_t>(kNodeChildCount)}) ||
      !ContainsBytes(image, a, kAddTailWindow,
                     {0x8b, 0x46, static_cast<uint8_t>(kNodeChildren)})) {
    return SiteResult::kAddShape;
  }
  uint32_t tail = 0u;
  if (!ContainsBytes(image, a, kAddTailWindow,
                     {0xff, 0x75, 0x08, 0x8b, 0xcb, 0xe8}, &tail) ||
      !CallTarget(image, tail + 5u, &s.process)) {
    return SiteResult::kAddShape;
  }
  // PROCESS: `mov eax,[ebx+0Ch]` at its head, `push "ruby"; lea ecx,
  // [ebx+10h]` (the tag compare), and `cmp eax,2` followed by
  // `push dword [ebx+28h]` (a text node's string).
  const uint32_t p = s.process;
  if (!ContainsBytes(image, p, 0x60u,
                     {0x8b, 0x43, static_cast<uint8_t>(kNodeType)})) {
    return SiteResult::kProcessShape;
  }
  bool ruby = false;
  for (const uint32_t push : FindStringPushes(image, kTagRuby, 64u)) {
    if (push < p || push >= p + kProcessWindow) continue;
    if (Match(image, push + 5u, {0x8d, 0x4b, static_cast<uint8_t>(kNodeTag)})) {
      ruby = true;
      break;
    }
  }
  if (!ruby) return SiteResult::kProcessShape;
  bool text = false;
  for (uint32_t at = p; at < p + kProcessWindow && !text; ++at) {
    if (!Match(image, at, {0x83, 0xf8, static_cast<uint8_t>(kNodeTypeText)})) {
      continue;
    }
    text = ContainsBytes(image, at, kTextNodeWindow,
                         {0xff, 0x73, static_cast<uint8_t>(kNodeText)});
  }
  if (!text) return SiteResult::kProcessShape;
  *out = s;
  return SiteResult::kResolved;
}

// ── message text (game thread, through a fault-safe reader) ────────────────

// Reads `bytes` at `address` of the game; false on a fault.
using ReadMemoryFn = bool (*)(void* context, uintptr_t address, void* out,
                              uint32_t bytes);

enum class TextResult : uint32_t {
  kOk = 0u,
  kFault = 1u,
  kTooLong = 2u,
  kTooManyNodes = 3u,
  kTooDeep = 4u,
  kBadNode = 5u,
};

// The displayed text of a message node tree: text nodes in document order,
// every element's children (a <ruby> element's children are its base; the
// reading is an attribute and never read), CR/LF dropped.  Bounded:
// kMaxMessageUnits units, kMaxNodes nodes, kMaxDepth levels.
inline TextResult CollectMessageText(ReadMemoryFn read, void* context,
                                     uintptr_t root, wchar_t* out,
                                     uint32_t capacity, uint32_t* length) {
  *length = 0u;
  if (root == 0u) return TextResult::kBadNode;
  struct Frame {
    uintptr_t children = 0u;
    uint32_t count = 0u;
    uint32_t next = 0u;
  };
  Frame stack[kMaxDepth] = {};
  uint32_t depth = 0u;
  uint32_t visited = 0u;
  uintptr_t node = root;
  for (;;) {
    if (node != 0u) {
      if (++visited > kMaxNodes) return TextResult::kTooManyNodes;
      uint32_t type = 0u;
      if (!read(context, node + kNodeType, &type, 4u)) return TextResult::kFault;
      if (type == kNodeTypeText) {
        uint32_t chars = 0u;
        int32_t units = 0;
        if (!read(context, node + kNodeText, &chars, 4u) ||
            !read(context, node + kNodeText + 4u, &units, 4u)) {
          return TextResult::kFault;
        }
        if (units < 0 || static_cast<uint32_t>(units) > kMaxTextNodeUnits) {
          return TextResult::kBadNode;
        }
        if (units > 0 && chars == 0u) return TextResult::kBadNode;
        wchar_t chunk[64] = {};
        uint32_t done = 0u;
        while (done < static_cast<uint32_t>(units)) {
          const uint32_t take =
              (std::min)(static_cast<uint32_t>(units) - done, 64u);
          if (!read(context, chars + done * 2u, chunk, take * 2u)) {
            return TextResult::kFault;
          }
          for (uint32_t i = 0u; i < take; ++i) {
            const wchar_t c = chunk[i];
            if (c == L'\r' || c == L'\n') continue;
            if (c == 0) return TextResult::kBadNode;
            if (*length >= capacity) return TextResult::kTooLong;
            out[(*length)++] = c;
          }
          done += take;
        }
      } else if (type == kNodeTypeElement || type == kNodeTypeDocument) {
        uint32_t children = 0u;
        uint32_t count = 0u;
        if (!read(context, node + kNodeChildren, &children, 4u) ||
            !read(context, node + kNodeChildCount, &count, 4u)) {
          return TextResult::kFault;
        }
        if (count > kMaxChildren || (count != 0u && children == 0u)) {
          return TextResult::kBadNode;
        }
        if (count != 0u) {
          if (depth >= kMaxDepth) return TextResult::kTooDeep;
          stack[depth++] = {children, count, 0u};
        }
      } else {
        return TextResult::kBadNode;
      }
    }
    // Next sibling, climbing out of finished child lists.
    node = 0u;
    while (depth != 0u && stack[depth - 1u].next >= stack[depth - 1u].count) {
      --depth;
    }
    if (depth == 0u) break;
    Frame& top = stack[depth - 1u];
    uint32_t child = 0u;
    if (!read(context, top.children + top.next * 4u, &child, 4u)) {
      return TextResult::kFault;
    }
    ++top.next;
    node = child;  // a null slot is skipped (the engine skips it too)
  }
  return TextResult::kOk;
}

// ── page model (HookWorker) ────────────────────────────────────────────────

// One message sprite's page as the VM fills it.  The VM gives a click unit
// to the window in one script step (one or more AddMessage calls); the
// window keeps adding units to the page until ClearMessage.  A unit is
// published once a whole worker interval passed without another add or
// clear on that sprite, and only the text added since the page's previous
// publication goes out, so each click unit is one line.
struct PageState {
  uintptr_t sprite = 0u;
  std::wstring page;           // the page so far
  size_t published = 0u;       // units of `page` already published
  uint64_t last_change_tick = 0u;
  uint64_t page_seq = 0u;
  bool dirty = false;
};

inline constexpr size_t kMaxSprites = 8u;

struct PageModel {
  std::array<PageState, kMaxSprites> sprites{};
  uint64_t next_page_seq = 0u;
};

inline PageState* SpriteState(PageModel* model, uintptr_t sprite) {
  PageState* free_slot = nullptr;
  PageState* oldest = nullptr;
  for (PageState& state : model->sprites) {
    if (state.sprite == sprite) return &state;
    if (state.sprite == 0u && free_slot == nullptr) free_slot = &state;
    if (oldest == nullptr || state.last_change_tick < oldest->last_change_tick) {
      oldest = &state;
    }
  }
  PageState* slot = free_slot != nullptr ? free_slot : oldest;
  *slot = PageState{};
  slot->sprite = sprite;
  slot->page_seq = ++model->next_page_seq;
  return slot;
}

inline void OnClear(PageModel* model, uintptr_t sprite, uint64_t tick) {
  PageState* state = SpriteState(model, sprite);
  // A unit added and wiped inside one tick was never readable: dropped.
  state->page.clear();
  state->published = 0u;
  state->dirty = false;
  state->last_change_tick = tick;
  state->page_seq = ++model->next_page_seq;
}

inline void OnAdd(PageModel* model, uintptr_t sprite, const wchar_t* text,
                  size_t units, uint64_t tick) {
  PageState* state = SpriteState(model, sprite);
  if (state->page.size() + units > 4u * kMaxMessageUnits) {
    // A page that never clears (a log window) restarts instead of growing.
    state->page.clear();
    state->published = 0u;
    state->page_seq = ++model->next_page_seq;
  }
  state->page.append(text, units);
  state->dirty = true;
  state->last_change_tick = tick;
}

struct Publication {
  uintptr_t sprite = 0u;
  uint64_t page_seq = 0u;
  std::wstring text;
};

// Worker tick `tick` (a counter, one per HookWorker pass, called after the
// pass replayed its events): every sprite whose last change was replayed in
// an earlier pass publishes its unit.  A whole worker interval without an
// add or clear on that sprite means the script step that added the unit is
// over (a step adds its unit in one run of the VM thread).
inline std::vector<Publication> OnTick(PageModel* model, uint64_t tick) {
  std::vector<Publication> out;
  for (PageState& state : model->sprites) {
    if (state.sprite == 0u || !state.dirty) continue;
    if (tick <= state.last_change_tick) continue;  // still in the step
    state.dirty = false;
    if (state.published >= state.page.size()) continue;
    std::wstring unit = state.page.substr(state.published);
    state.published = state.page.size();
    // Leading/trailing blanks of a unit are layout, not text.
    const size_t first = unit.find_first_not_of(L" \t\x3000");
    if (first == std::wstring::npos) continue;
    const size_t last = unit.find_last_not_of(L" \t\x3000");
    out.push_back({state.sprite, state.page_seq,
                   unit.substr(first, last - first + 1u)});
  }
  return out;
}

}  // namespace fushi_voice_hook::entisgls
