#include "foreground_selection.h"

#include <windows.h>

#include <objbase.h>
#include <uiautomation.h>
#include <wrl/client.h>

#include <string>

// TODO-1030 M0 — UI Automation implementation of the foreground-selection
// context capture (see foreground_selection.h). Pure UIA + COM; no clipboard,
// no key injection. Runs on a caller-provided worker thread.

namespace {

using Microsoft::WRL::ComPtr;

// Converts a COM BSTR (UTF-16) to a UTF-8 std::string. Empty / null BSTR -> "".
std::string BstrToUtf8(BSTR value) {
  if (value == nullptr) {
    return std::string();
  }
  const int wide_len = static_cast<int>(SysStringLen(value));
  if (wide_len <= 0) {
    return std::string();
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, wide_len, nullptr, 0,
                                        nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, wide_len, result.data(), size, nullptr,
                      nullptr);
  return result;
}

// RAII wrapper: read one text range's whole text (GetText(-1)) into UTF-8 and
// report its UTF-16 code-unit length (the unit Dart String offsets use). Returns
// false on failure. [utf16_len] is the raw BSTR length BEFORE UTF-8 conversion.
bool RangeText(IUIAutomationTextRange* range, std::string* out_utf8,
               int* utf16_len) {
  if (range == nullptr) {
    return false;
  }
  BSTR bstr = nullptr;
  HRESULT hr = range->GetText(-1, &bstr);
  if (FAILED(hr)) {
    return false;
  }
  *utf16_len = static_cast<int>(SysStringLen(bstr));
  *out_utf8 = BstrToUtf8(bstr);
  SysFreeString(bstr);
  return true;
}

// Resolves the UI Automation TextPattern for [start], walking UP the ancestor
// chain (ControlView) when the focused leaf itself has none. Keyboard focus in
// browsers / rich editors often lands on a pane or inline leaf whose Text
// pattern actually lives on the document ancestor, so the focused element alone
// misses it (GetCurrentPattern returns null). Bounded to a small depth so a
// pathological tree can never spin. Returns null when no ancestor exposes it.
ComPtr<IUIAutomationTextPattern> ResolveTextPattern(
    IUIAutomation* automation, IUIAutomationElement* start) {
  if (automation == nullptr || start == nullptr) {
    return nullptr;
  }
  ComPtr<IUIAutomationTreeWalker> walker;
  if (FAILED(automation->get_ControlViewWalker(&walker)) || walker == nullptr) {
    walker = nullptr;  // Still try the start element itself below.
  }
  ComPtr<IUIAutomationElement> node = start;
  ComPtr<IUIAutomationElement> top = start;
  for (int depth = 0; node != nullptr && depth < 12; depth++) {
    ComPtr<IUnknown> unknown;
    if (SUCCEEDED(node->GetCurrentPattern(UIA_TextPatternId, &unknown)) &&
        unknown != nullptr) {
      ComPtr<IUIAutomationTextPattern> text_pattern;
      if (SUCCEEDED(unknown.As(&text_pattern)) && text_pattern != nullptr) {
        return text_pattern;
      }
    }
    top = node;
    if (walker == nullptr) {
      break;
    }
    ComPtr<IUIAutomationElement> parent;
    if (FAILED(walker->GetParentElement(node.Get(), &parent)) ||
        parent == nullptr) {
      break;
    }
    node = parent;
  }

  // Neither the focused element nor its ancestors expose a TextPattern. Many
  // apps (UWP text controls, browser document panes) put keyboard focus on a
  // Custom/Group container while the TextPattern lives on a DESCENDANT document
  // element. From the highest ancestor reached, find the first descendant that
  // advertises a TextPattern (IsTextPatternAvailable) and use it. Bounded by
  // UIA's own subtree scope; returns null when the tree has no text provider.
  if (top != nullptr) {
    VARIANT want;
    VariantInit(&want);
    want.vt = VT_BOOL;
    want.boolVal = VARIANT_TRUE;
    ComPtr<IUIAutomationCondition> has_text;
    if (SUCCEEDED(automation->CreatePropertyCondition(
            UIA_IsTextPatternAvailablePropertyId, want, &has_text)) &&
        has_text != nullptr) {
      ComPtr<IUIAutomationElement> found;
      if (SUCCEEDED(top->FindFirst(TreeScope_Subtree, has_text.Get(), &found)) &&
          found != nullptr) {
        ComPtr<IUnknown> unknown;
        if (SUCCEEDED(
                found->GetCurrentPattern(UIA_TextPatternId, &unknown)) &&
            unknown != nullptr) {
          ComPtr<IUIAutomationTextPattern> text_pattern;
          if (SUCCEEDED(unknown.As(&text_pattern)) &&
              text_pattern != nullptr) {
            VariantClear(&want);
            return text_pattern;
          }
        }
      }
    }
    VariantClear(&want);
  }
  return nullptr;
}

}  // namespace

ForegroundSelectionResult CaptureForegroundSelectionContext(int max_expand) {
  ForegroundSelectionResult out;
  if (max_expand < 0) {
    max_expand = 0;
  }

  // COM must be initialised on THIS (worker) thread. Apartment-threaded matches
  // the UIA usage; balanced by CoUninitialize before return. RPC_E_CHANGED_MODE
  // means COM was already init'd on this thread in another mode — still usable,
  // just don't uninit in that case.
  const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool should_uninit = (com_hr == S_OK || com_hr == S_FALSE);

  {
    ComPtr<IUIAutomation> automation;
    HRESULT hr = CoCreateInstance(CLSID_CUIAutomation, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&automation));
    if (FAILED(hr) || automation == nullptr) {
      if (should_uninit) CoUninitialize();
      return out;
    }

    ComPtr<IUIAutomationElement> focused;
    hr = automation->GetFocusedElement(&focused);
    if (FAILED(hr) || focused == nullptr) {
      if (should_uninit) CoUninitialize();
      return out;
    }

    // Resolve the TextPattern from the focused element, walking up ancestors
    // (browsers/editors often focus a leaf whose TextPattern lives on the
    // document ancestor). Null = this app exposes no text selection to UIA.
    ComPtr<IUIAutomationTextPattern> text_pattern =
        ResolveTextPattern(automation.Get(), focused.Get());
    if (text_pattern == nullptr) {
      if (should_uninit) CoUninitialize();
      return out;
    }

    ComPtr<IUIAutomationTextRangeArray> selection;
    hr = text_pattern->GetSelection(&selection);
    if (FAILED(hr) || selection == nullptr) {
      if (should_uninit) CoUninitialize();
      return out;
    }
    int length = 0;
    if (FAILED(selection->get_Length(&length)) || length <= 0) {
      if (should_uninit) CoUninitialize();
      return out;
    }
    ComPtr<IUIAutomationTextRange> sel_range;
    if (FAILED(selection->GetElement(0, &sel_range)) || sel_range == nullptr) {
      if (should_uninit) CoUninitialize();
      return out;
    }

    // The selected text itself (may legitimately be empty for a caret-only
    // "selection"; then there is nothing to look up — bail so the clipboard
    // fallback can try instead).
    std::string sel_text;
    int sel_utf16 = 0;
    if (!RangeText(sel_range.Get(), &sel_text, &sel_utf16) ||
        sel_utf16 <= 0) {
      if (should_uninit) CoUninitialize();
      return out;
    }

    // BEFORE context: clone the selection, collapse its END back onto the
    // selection START, then push its START back up to max_expand characters.
    std::string before_text;
    int before_utf16 = 0;
    ComPtr<IUIAutomationTextRange> before_range;
    if (SUCCEEDED(sel_range->Clone(&before_range)) && before_range != nullptr) {
      before_range->MoveEndpointByRange(TextPatternRangeEndpoint_End,
                                        sel_range.Get(),
                                        TextPatternRangeEndpoint_Start);
      int moved = 0;
      before_range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,
                                       TextUnit_Character, -max_expand, &moved);
      RangeText(before_range.Get(), &before_text, &before_utf16);
    }

    // AFTER context: clone the selection, collapse its START forward onto the
    // selection END, then push its END down to max_expand characters.
    std::string after_text;
    int after_utf16 = 0;
    ComPtr<IUIAutomationTextRange> after_range;
    if (SUCCEEDED(sel_range->Clone(&after_range)) && after_range != nullptr) {
      after_range->MoveEndpointByRange(TextPatternRangeEndpoint_Start,
                                       sel_range.Get(),
                                       TextPatternRangeEndpoint_End);
      int moved = 0;
      after_range->MoveEndpointByUnit(TextPatternRangeEndpoint_End,
                                      TextUnit_Character, max_expand, &moved);
      RangeText(after_range.Get(), &after_text, &after_utf16);
    }

    out.text = before_text + sel_text + after_text;
    out.sel_start = before_utf16;  // UTF-16 code-unit offset (Dart String unit).
    out.sel_len = sel_utf16;
    out.ok = true;
  }

  if (should_uninit) {
    CoUninitialize();
  }
  return out;
}
