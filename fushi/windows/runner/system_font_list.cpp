#include "system_font_list.h"

#include <dwrite.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <wchar.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#include "utils.h"

namespace fushi {
namespace {

// Picks the family name Skia's DirectWrite font manager matches on: the
// en-us localized name when present, otherwise the first localized name.
std::wstring FamilyNameOf(IDWriteFontFamily* family) {
  Microsoft::WRL::ComPtr<IDWriteLocalizedStrings> names;
  if (FAILED(family->GetFamilyNames(&names)) || names == nullptr ||
      names->GetCount() == 0) {
    return std::wstring();
  }
  UINT32 index = 0;
  BOOL exists = FALSE;
  if (FAILED(names->FindLocaleName(L"en-us", &index, &exists)) || !exists) {
    index = 0;
  }
  UINT32 length = 0;
  if (FAILED(names->GetStringLength(index, &length))) {
    return std::wstring();
  }
  std::wstring name(static_cast<size_t>(length) + 1, L'\0');
  if (FAILED(names->GetString(index, name.data(), length + 1))) {
    return std::wstring();
  }
  name.resize(length);
  return name;
}

// True when the family's regular (normal weight/stretch/style) face maps both
// U+3042 'あ' and U+6F22 '漢'. Only the face's own cmap is consulted — no
// fallback — so this reflects the font itself.
bool FamilySupportsJapanese(IDWriteFontFamily* family) {
  Microsoft::WRL::ComPtr<IDWriteFont> font;
  if (FAILED(family->GetFirstMatchingFont(
          DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
          DWRITE_FONT_STYLE_NORMAL, &font)) ||
      font == nullptr) {
    return false;
  }
  BOOL has_kana = FALSE;
  BOOL has_kanji = FALSE;
  if (FAILED(font->HasCharacter(0x3042, &has_kana)) || !has_kana) {
    return false;
  }
  if (FAILED(font->HasCharacter(0x6F22, &has_kanji))) {
    return false;
  }
  return has_kanji == TRUE;
}

struct WideFamily {
  std::wstring name;
  bool supports_japanese;
};

}  // namespace

std::vector<SystemFontFamily> EnumerateSystemFontFamilies() {
  std::vector<SystemFontFamily> out;
  Microsoft::WRL::ComPtr<IDWriteFactory> factory;
  if (FAILED(DWriteCreateFactory(
          DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
          reinterpret_cast<IUnknown**>(factory.GetAddressOf())))) {
    return out;
  }
  Microsoft::WRL::ComPtr<IDWriteFontCollection> collection;
  if (FAILED(factory->GetSystemFontCollection(&collection, TRUE)) ||
      collection == nullptr) {
    return out;
  }

  std::vector<WideFamily> families;
  const UINT32 count = collection->GetFontFamilyCount();
  families.reserve(count);
  for (UINT32 i = 0; i < count; ++i) {
    Microsoft::WRL::ComPtr<IDWriteFontFamily> family;
    if (FAILED(collection->GetFontFamily(i, &family)) || family == nullptr) {
      continue;
    }
    std::wstring name = FamilyNameOf(family.Get());
    // '@'-prefixed families are GDI vertical-writing aliases, not families a
    // CSS / Flutter fontFamily lookup should offer.
    if (name.empty() || name[0] == L'@') {
      continue;
    }
    families.push_back({std::move(name), FamilySupportsJapanese(family.Get())});
  }

  std::sort(families.begin(), families.end(),
            [](const WideFamily& a, const WideFamily& b) {
              return _wcsicmp(a.name.c_str(), b.name.c_str()) < 0;
            });
  WideFamily* previous = nullptr;
  for (WideFamily& family : families) {
    if (previous != nullptr &&
        _wcsicmp(previous->name.c_str(), family.name.c_str()) == 0) {
      // Duplicate (case-insensitive): keep one entry, but don't lose a
      // positive Japanese-coverage signal from the duplicate.
      if (family.supports_japanese && !out.empty()) {
        out.back().supports_japanese = true;
      }
      continue;
    }
    std::string utf8 = Utf8FromUtf16(family.name.c_str());
    if (utf8.empty()) {
      continue;
    }
    out.push_back({std::move(utf8), family.supports_japanese});
    previous = &family;
  }
  return out;
}

}  // namespace fushi

void RegisterSystemFontListChannel(flutter::BinaryMessenger* messenger) {
  // Process-lifetime channel: the runner has exactly one main-window engine,
  // and MethodChannel's destructor never touches the messenger, so a static
  // holder is safe through shutdown.
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "app.fushi.reader/fonts",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "listSystemFonts") {
          result->NotImplemented();
          return;
        }
        // Runs synchronously on the platform thread: DirectWrite's system
        // collection is served by the OS font cache, and enumerating ~150
        // families plus one cmap probe each measured ~80 ms warm / ~155 ms
        // cold on a dev box. That one-shot stall on a user-initiated page
        // open is cheaper than adding a worker + UI-thread reply hop here
        // (MethodResult must complete on the platform thread).
        flutter::EncodableList list;
        for (const fushi::SystemFontFamily& family :
             fushi::EnumerateSystemFontFamilies()) {
          list.emplace_back(flutter::EncodableMap{
              {flutter::EncodableValue("family"),
               flutter::EncodableValue(family.family)},
              {flutter::EncodableValue("supportsJapanese"),
               flutter::EncodableValue(family.supports_japanese)},
          });
        }
        result->Success(flutter::EncodableValue(std::move(list)));
      });
}
