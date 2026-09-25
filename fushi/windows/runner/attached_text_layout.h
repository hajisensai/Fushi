#ifndef RUNNER_ATTACHED_TEXT_LAYOUT_H_
#define RUNNER_ATTACHED_TEXT_LAYOUT_H_

#include <dwrite.h>
#include <dwrite_1.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "attached_layout_validation.h"

// The runtime catch surface and offline calibration previews use this one
// DirectWrite implementation. Coordinates are physical pixels; no HWND,
// provider admission or input state is read or changed here.
namespace fushi::attached_text_layout {

struct NormalizedRect {
  double left = 0.0;
  double top = 0.0;
  double width = 0.0;
  double height = 0.0;
};

struct ReferenceClient {
  int width_px = 0;
  int height_px = 0;
  int dpi = 96;
};

struct CellGrid {
  double advance_per_client_height = std::numeric_limits<double>::quiet_NaN();
  double line_advance_per_client_height =
      std::numeric_limits<double>::quiet_NaN();
  double cell_height_per_client_height =
      std::numeric_limits<double>::quiet_NaN();
  // Optional actual line capacity.  The legacy integer columns field remains
  // the default and still bounds continuation indents.
  double line_width_in_cells = std::numeric_limits<double>::quiet_NaN();
  int columns = 0;
  double continuation_indent = std::numeric_limits<double>::quiet_NaN();
  double quoted_continuation_indent =
      std::numeric_limits<double>::quiet_NaN();
  bool hanging_punctuation = false;
  bool trim_wrap_whitespace = false;
  // Calibration proved this game's rows come from Hook line breaks. Every
  // sentence then follows only those breaks: a line is never wrapped at the
  // calibrated width, and rows may extend past the calibrated body to the
  // client edge, because a short calibration sentence cannot bound them.
  bool explicit_line_breaks = false;

  bool operator==(const CellGrid &other) const {
    const bool same_line_width =
        (std::isnan(line_width_in_cells) &&
         std::isnan(other.line_width_in_cells)) ||
        line_width_in_cells == other.line_width_in_cells;
    const bool same_continuation_indent =
        (std::isnan(continuation_indent) &&
         std::isnan(other.continuation_indent)) ||
        continuation_indent == other.continuation_indent;
    const bool same_quoted_continuation_indent =
        (std::isnan(quoted_continuation_indent) &&
         std::isnan(other.quoted_continuation_indent)) ||
        quoted_continuation_indent == other.quoted_continuation_indent;
    return advance_per_client_height == other.advance_per_client_height &&
           line_advance_per_client_height ==
               other.line_advance_per_client_height &&
           cell_height_per_client_height ==
               other.cell_height_per_client_height &&
           same_line_width &&
           columns == other.columns &&
           same_continuation_indent && same_quoted_continuation_indent &&
           hanging_punctuation == other.hanging_punctuation &&
           trim_wrap_whitespace == other.trim_wrap_whitespace &&
           explicit_line_breaks == other.explicit_line_breaks;
  }

  bool operator!=(const CellGrid &other) const { return !(*this == other); }
};

struct PunctuationVisualBounds {
  uint32_t code_point = 0;
  double left = 0.0;
  double top = 0.0;
  double right = 1.0;
  double bottom = 1.0;
};

struct CharacterAdvance {
  uint32_t code_point = 0;
  double advance_ratio = 1.0;
};

inline bool IsPunctuationOrSymbolCodePoint(uint32_t code_point) {
  // Keep the override schema BMP-only. DirectWrite and Windows NLS use
  // UTF-16 code units here; rejecting supplementary code points keeps the
  // classifier conservative and avoids deriving a visual override that the
  // native admission path cannot classify consistently.
  if (code_point < 0x20 || code_point > 0xFFFF ||
      (code_point >= 0xD800 && code_point <= 0xDFFF)) {
    return false;
  }
  const wchar_t utf16 = static_cast<wchar_t>(code_point);
  WORD ctype1[2]{};
  WORD ctype3[2]{};
  if (!GetStringTypeExW(LOCALE_INVARIANT, CT_CTYPE1, &utf16, 1, ctype1) ||
      !GetStringTypeExW(LOCALE_INVARIANT, CT_CTYPE3, &utf16, 1, ctype3)) {
    return false;
  }
  return (ctype1[0] & C1_PUNCT) != 0 || (ctype3[0] & C3_SYMBOL) != 0;
}

inline bool IsPunctuationVisualBoundsValid(
    const PunctuationVisualBounds &bounds) {
  return bounds.code_point >= 0x20 && bounds.code_point <= 0x10FFFF &&
         !(bounds.code_point >= 0xD800 && bounds.code_point <= 0xDFFF) &&
         IsPunctuationOrSymbolCodePoint(bounds.code_point) &&
         std::isfinite(bounds.left) && std::isfinite(bounds.top) &&
         std::isfinite(bounds.right) && std::isfinite(bounds.bottom) &&
         bounds.left >= 0.0 && bounds.top >= 0.0 && bounds.right <= 1.0 &&
         bounds.bottom <= 1.0 && bounds.right > bounds.left &&
         bounds.bottom > bounds.top && bounds.right - bounds.left >= 0.02 &&
         bounds.bottom - bounds.top >= 0.02;
}

inline bool IsCellGridValid(const CellGrid &grid) {
  const double maximum_indent =
      std::min(static_cast<double>(grid.columns - 1), 8.0);
  const bool line_width_valid =
      std::isnan(grid.line_width_in_cells) ||
      (std::isfinite(grid.line_width_in_cells) &&
       grid.line_width_in_cells >= 2.0 && grid.line_width_in_cells <= 128.0);
  return std::isfinite(grid.advance_per_client_height) &&
         grid.advance_per_client_height >= 0.001 &&
         grid.advance_per_client_height <= 0.25 &&
         std::isfinite(grid.line_advance_per_client_height) &&
         grid.line_advance_per_client_height >= 0.001 &&
         grid.line_advance_per_client_height <= 0.25 &&
         std::isfinite(grid.cell_height_per_client_height) &&
         grid.cell_height_per_client_height >= 0.001 &&
         grid.cell_height_per_client_height <= 0.25 &&
         grid.line_advance_per_client_height >=
             grid.cell_height_per_client_height &&
         line_width_valid && grid.columns >= 2 && grid.columns <= 128 &&
         std::isfinite(grid.continuation_indent) &&
         grid.continuation_indent >= -1 &&
         grid.continuation_indent <= maximum_indent &&
         std::isfinite(grid.quoted_continuation_indent) &&
         grid.quoted_continuation_indent >= -1 &&
         grid.quoted_continuation_indent <= maximum_indent;
}

struct Layout {
  std::wstring font_family = L"Yu Gothic";
  double font_size_per_client_height = 0.045;
  double letter_spacing_per_client_height = 0.0;
  double line_height = 1.0;
  std::string text_align = "left";
  std::string vertical_align = "top";
  double padding_per_client_height = 0.0;
  std::optional<CellGrid> cell_grid;
  bool quoted_text_only = false;
  std::vector<PunctuationVisualBounds> punctuation_visual_bounds;
  // MethodChannel decoding is fail-closed.  A present but malformed list
  // must never silently become the legacy layout.
  bool punctuation_visual_bounds_valid = true;
  std::vector<CharacterAdvance> character_advances;
  // MethodChannel decoding is fail-closed. A present but malformed list must
  // never silently become a legacy layout.
  bool character_advances_valid = true;
};

inline bool IsPunctuationVisualBoundsListValid(const Layout &layout) {
  if (!layout.punctuation_visual_bounds_valid ||
      layout.punctuation_visual_bounds.size() > 32) {
    return false;
  }
  for (size_t index = 0; index < layout.punctuation_visual_bounds.size();
       ++index) {
    const PunctuationVisualBounds &bounds =
        layout.punctuation_visual_bounds[index];
    if (!IsPunctuationVisualBoundsValid(bounds)) return false;
    for (size_t previous = 0; previous < index; ++previous) {
      if (layout.punctuation_visual_bounds[previous].code_point ==
          bounds.code_point) {
        return false;
      }
    }
  }
  return layout.punctuation_visual_bounds.empty() ||
         layout.cell_grid.has_value();
}

inline bool IsUnicodeWhitespace(uint32_t code_point) {
  if (code_point == 0x20 || code_point == 0x85 || code_point == 0xA0 ||
      code_point == 0x1680 || code_point == 0x2028 ||
      code_point == 0x2029 || code_point == 0x202F ||
      code_point == 0x205F || code_point == 0x3000 || code_point == 0xFEFF) {
    return true;
  }
  return code_point >= 0x2000 && code_point <= 0x200A;
}

inline bool IsUnicodeControlOrFormat(uint32_t code_point) {
  if (code_point <= 0x1F || (code_point >= 0x7F && code_point <= 0x9F)) {
    return true;
  }
  if (code_point == 0x00AD || code_point == 0x061C ||
      code_point == 0x06DD || code_point == 0x070F ||
      code_point == 0x180E || code_point == 0xFEFF ||
      (code_point >= 0x0600 && code_point <= 0x0605) ||
      (code_point >= 0x0890 && code_point <= 0x0891) ||
      (code_point >= 0x200B && code_point <= 0x200F) ||
      (code_point >= 0x202A && code_point <= 0x202E) ||
      (code_point >= 0x2060 && code_point <= 0x2064) ||
      (code_point >= 0x2066 && code_point <= 0x206F) ||
      (code_point >= 0xFFF9 && code_point <= 0xFFFB) ||
      code_point == 0x110BD || code_point == 0x110CD ||
      (code_point >= 0x13430 && code_point <= 0x1343F) ||
      (code_point >= 0x1BCA0 && code_point <= 0x1BCA3) ||
      (code_point >= 0x1D173 && code_point <= 0x1D17A) ||
      code_point == 0xE0001 ||
      (code_point >= 0xE0020 && code_point <= 0xE007F)) {
    return true;
  }
  return false;
}

inline bool IsCharacterAdvanceCodePoint(uint32_t code_point) {
  return code_point <= 0x10FFFF &&
         !(code_point >= 0xD800 && code_point <= 0xDFFF) &&
         !IsUnicodeControlOrFormat(code_point) &&
         // An ordinary ASCII space can have a measured proportional advance,
         // but it remains non-clickable in the grid layout. Other whitespace
         // stays rejected so controls and invisible separators cannot become
         // persisted character overrides.
         (code_point == 0x20 || !IsUnicodeWhitespace(code_point));
}

inline bool IsCharacterAdvanceValid(const CharacterAdvance &advance) {
  return IsCharacterAdvanceCodePoint(advance.code_point) &&
         std::isfinite(advance.advance_ratio) &&
         advance.advance_ratio >= 0.15 && advance.advance_ratio <= 2.0;
}

inline bool IsCharacterAdvancesListValid(const Layout &layout) {
  if (!layout.character_advances_valid ||
      layout.character_advances.size() > 64) {
    return false;
  }
  for (size_t index = 0; index < layout.character_advances.size(); ++index) {
    const CharacterAdvance &advance = layout.character_advances[index];
    if (!IsCharacterAdvanceValid(advance)) return false;
    for (size_t previous = 0; previous < index; ++previous) {
      if (layout.character_advances[previous].code_point ==
          advance.code_point) {
        return false;
      }
    }
  }
  return layout.character_advances.empty() || layout.cell_grid.has_value();
}

inline const CharacterAdvance *FindCharacterAdvance(const Layout &layout,
                                                     uint32_t code_point) {
  for (const CharacterAdvance &advance : layout.character_advances) {
    if (advance.code_point == code_point) return &advance;
  }
  return nullptr;
}

inline double CharacterAdvanceRatio(const Layout &layout, uint32_t code_point) {
  const CharacterAdvance *advance = FindCharacterAdvance(layout, code_point);
  return advance == nullptr ? 1.0 : advance->advance_ratio;
}

inline double EffectiveLineWidthInCells(const CellGrid &grid) {
  return std::isfinite(grid.line_width_in_cells)
             ? grid.line_width_in_cells
             : static_cast<double>(grid.columns);
}

struct ClusterBox {
  uint32_t text_position = 0;
  uint32_t text_length = 0;
  RECT hit_rect{};
  RECT visual_rect{};
};

struct Result {
  Microsoft::WRL::ComPtr<IDWriteTextLayout> text_layout;
  std::vector<ClusterBox> boxes;
  std::string reason;

  bool ok() const { return reason.empty(); }
};

inline Result Failure(const char *reason) {
  Result result;
  result.reason = reason;
  return result;
}

inline bool IsNormalizedRectValid(const NormalizedRect &rect) {
  return std::isfinite(rect.left) && std::isfinite(rect.top) &&
         std::isfinite(rect.width) && std::isfinite(rect.height) &&
         rect.width >= 0.002 && rect.height >= 0.002 && rect.left >= 0.0 &&
         rect.top >= 0.0 && rect.left + rect.width <= 1.0 &&
         rect.top + rect.height <= 1.0;
}

inline RECT ResolveBodyRect(const RECT &client,
                            const NormalizedRect &normalized) {
  const double width = static_cast<double>(client.right - client.left);
  const double height = static_cast<double>(client.bottom - client.top);
  // Keep the integer body as an outer approximation of the normalized body.
  // Rounding both edges to nearest can make a mathematically compatible body
  // one pixel narrower after a resize, even though the calibrated grid still
  // fits in the continuous region.
  const LONG left =
      client.left + static_cast<LONG>(std::floor(normalized.left * width));
  const LONG top =
      client.top + static_cast<LONG>(std::floor(normalized.top * height));
  const LONG right =
      client.left + static_cast<LONG>(std::ceil(
          (normalized.left + normalized.width) * width));
  const LONG bottom =
      client.top + static_cast<LONG>(std::ceil(
          (normalized.top + normalized.height) * height));
  return RECT{left, top, right, bottom};
}

inline bool RectHasArea(const RECT &rect) {
  return rect.right > rect.left && rect.bottom > rect.top;
}

inline bool IsGridSupportedTextUnit(uint32_t code) {
  if (code == L'\r' || code == L'\n' || code == L' ' || code == L'\t' ||
      code == 0x3000) {
    return true;
  }
  // The cell grid is a geometry contract, not a Japanese-character allow
  // list.  Hook text may contain Latin, symbols, emoji and game-specific
  // punctuation; rejecting those before building boxes made a valid profile
  // unusable in another game.  Control characters remain invalid because
  // they have no deterministic cell semantics.
  return code >= 0x20 && code <= 0x10FFFF &&
         !(code >= 0x7F && code <= 0x9F) &&
         !(code >= 0xD800 && code <= 0xDFFF);
}

inline bool IsGridCombiningMark(uint32_t code) {
  return (code >= 0x0300 && code <= 0x036F) ||
         (code >= 0x1AB0 && code <= 0x1AFF) ||
         (code >= 0x1DC0 && code <= 0x1DFF) ||
         (code >= 0x20D0 && code <= 0x20FF) ||
         (code >= 0xFE00 && code <= 0xFE0F) ||
         (code >= 0xFE20 && code <= 0xFE2F) ||
         (code >= 0x1F3FB && code <= 0x1F3FF) ||
         (code >= 0xE0100 && code <= 0xE01EF);
}

inline bool IsHangingPunctuation(uint32_t code) {
  // Small kana cannot begin a line in ordinary Japanese kinsoku layout.
  // Keep this set in sync with the calibration fitter; no engine-name rules.
  static constexpr wchar_t kSmallKana[] =
      L"\u3041\u3043\u3045\u3047\u3049\u3063\u3083\u3085\u3087\u308E"
      L"\u30A1\u30A3\u30A5\u30A7\u30A9\u30C3\u30E3\u30E5\u30E7\u30EE\u30F5\u30F6";
  for (const wchar_t kana : kSmallKana) {
    if (kana != 0 && code == static_cast<uint32_t>(kana)) return true;
  }
  switch (code) {
    case L'\u300D':  // 」
    case L'\u300F':  // 』
    case L'\uFF09':  // ）
    case L')':
    case L']':
    case L'\uFF5D':  // ｝
    case L'}':
    case L'\u3011':  // 】
    case L'\u3015':  // 〕
    case L'\u3009':  // 〉
    case L'\u300B':  // 》
    case L'\u3001':  // 、
    case L'\u3002':  // 。
    case L'\uFF0C':  // ，
    case L'\uFF0E':  // ．
    case L'\uFF01':  // ！
    case L'\uFF1F':  // ？
    case L'!':
    case L'?':
      return true;
    default:
      return false;
  }
}

inline std::pair<size_t, size_t> GridSourceSpan(const std::wstring &source,
                                                const Layout &style) {
  size_t start = 0;
  size_t end = source.size();
  if (style.quoted_text_only) {
    const size_t opener = source.find(L'\u300C');
    if (opener != std::wstring::npos) {
      start = opener;
      const size_t closer = source.find(L'\u300D', opener + 1);
      if (closer != std::wstring::npos) end = closer + 1;
    }
  }
  return {start, end};
}

inline bool HasExplicitGridLineBreak(const std::wstring &source,
                                     const Layout &style) {
  if (!style.cell_grid.has_value() || source.empty()) return false;
  const auto [start, end] = GridSourceSpan(source, style);
  const size_t last_content = source.find_last_not_of(L"\r\n \t\u3000", end - 1);
  return last_content != std::wstring::npos &&
         last_content >= start &&
         source.find_first_of(L"\r\n", start) < last_content;
}

// Rows follow only Hook line breaks: this sentence has one, or calibration
// proved the game always breaks through the Hook text.
inline bool UsesHookLineBreaks(const std::wstring &source,
                               const Layout &style) {
  return style.cell_grid.has_value() &&
         (style.cell_grid->explicit_line_breaks ||
          HasExplicitGridLineBreak(source, style));
}

inline Result BuildCellGrid(const std::wstring &source, const Layout &style,
                            int client_height_px, int surface_width_px,
                            int surface_height_px,
                            const RECT &layout_bounds) {
  if (!style.cell_grid.has_value() || !IsCellGridValid(*style.cell_grid) ||
      !IsPunctuationVisualBoundsListValid(style) ||
      !IsCharacterAdvancesListValid(style))
    return Failure("invalid_layout");
  constexpr float kMinimumBodyPixels = 8.0f;
  const float layout_width =
      static_cast<float>(layout_bounds.right - layout_bounds.left);
  const float layout_height =
      static_cast<float>(layout_bounds.bottom - layout_bounds.top);
  if (layout_width < kMinimumBodyPixels || layout_height < kMinimumBodyPixels)
    return Failure("layout_bounds_too_small");

  const CellGrid &grid = *style.cell_grid;
  const double client_height =
      static_cast<double>(std::max(1, client_height_px));
  const double advance = grid.advance_per_client_height * client_height;
  const double line_advance =
      grid.line_advance_per_client_height * client_height;
  const double cell_height = grid.cell_height_per_client_height * client_height;
  const double bounds_left = static_cast<double>(layout_bounds.left);
  const double bounds_top = static_cast<double>(layout_bounds.top);
  const double bounds_right = static_cast<double>(layout_bounds.right);
  const double bounds_bottom = static_cast<double>(layout_bounds.bottom);
  const double line_width_in_cells = EffectiveLineWidthInCells(grid);
  const double maximum_line_width_in_cells =
      line_width_in_cells + (grid.hanging_punctuation ? 1.0 : 0.0);
  if (!std::isfinite(advance) || !std::isfinite(line_advance) ||
      !std::isfinite(cell_height) || !std::isfinite(line_width_in_cells) ||
      bounds_left + maximum_line_width_in_cells * advance >
          bounds_right || bounds_top + cell_height > bounds_bottom) {
    return Failure("grid_overflow_body_rect");
  }

  // Filter only for the grid. Keep original UTF-16 positions for Hook hits.
  const auto [start, end] = GridSourceSpan(source, style);
  const uint32_t source_start = static_cast<uint32_t>(start);
  const uint32_t source_end = static_cast<uint32_t>(end);
  // A Hook hard break owns every row boundary for this sentence. Keep the
  // saved width and wrapping unchanged for text without an explicit break,
  // unless calibration proved the game always breaks through the Hook text.
  const bool hard_break = UsesHookLineBreaks(source, style);
  // Only a profile calibrated as Hook-only may place rows below the saved
  // body; otherwise extra rows remain a body overflow, as before.
  const bool rows_extend_to_client = grid.explicit_line_breaks;
  const bool quoted =
      source_start < source_end &&
      (source[source_start] == L'\u300C' ||
       source[source_start] == L'\u300E');
  const double continuation_indent = quoted ? grid.quoted_continuation_indent
                                            : grid.continuation_indent;
  int row = 0;
  // The body contains the leftmost row. Signed indentation supports a first
  // row one cell to the right without moving later hit boxes outside the body.
  double cursor_in_cells = std::max(0.0, -continuation_indent);
  bool hanging_punctuation_used = false;
  bool pending_wrap_space = false;
  const auto advance_line = [&]() {
    ++row;
    cursor_in_cells = std::max(0.0, continuation_indent);
    hanging_punctuation_used = false;
  };
  const auto next_cell_bounds = [&](double left_in_cells, double width_in_cells,
                                    RECT *box) -> bool {
    const double left = bounds_left + left_in_cells * advance;
    const double top = bounds_top + static_cast<double>(row) * line_advance;
    const double right = left + width_in_cells * advance;
    const double bottom = top + cell_height;
    if (!std::isfinite(left) || !std::isfinite(top) ||
        !std::isfinite(right) || !std::isfinite(bottom) ||
        left < bounds_left || top < bounds_top ||
        right > (hard_break ? surface_width_px : bounds_right) ||
        bottom > (rows_extend_to_client ? surface_height_px : bounds_bottom) ||
        left < 0.0 || top < 0.0 ||
        right > static_cast<double>(surface_width_px) ||
        bottom > static_cast<double>(surface_height_px)) {
      return false;
    }
    *box = RECT{static_cast<LONG>(std::llround(left)),
                static_cast<LONG>(std::llround(top)),
                static_cast<LONG>(std::llround(right)),
                static_cast<LONG>(std::llround(bottom))};
    if (!RectHasArea(*box) || box->left < layout_bounds.left ||
        box->top < layout_bounds.top ||
        box->right > (hard_break ? surface_width_px : layout_bounds.right) ||
        box->bottom >
            (rows_extend_to_client ? surface_height_px
                                   : layout_bounds.bottom) ||
        box->left < 0 || box->top < 0 ||
        box->right > surface_width_px || box->bottom > surface_height_px) {
      return false;
    }
    return true;
  };

  Result result;
  bool previous_cell = false;
  for (uint32_t index = source_start; index < source_end; ++index) {
    uint32_t code = static_cast<uint16_t>(source[index]);
    uint32_t length = 1;
    if (code >= 0xD800 && code <= 0xDBFF && index + 1 < source_end) {
      const uint32_t low = static_cast<uint16_t>(source[index + 1]);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        length = 2;
      }
    }
    if (code == L'\r') {
      pending_wrap_space = false;
      if (index + 1 < source_end && source[index + 1] == L'\n') ++index;
      advance_line();
      previous_cell = false;
      continue;
    }
    if (code == L'\n') {
      pending_wrap_space = false;
      advance_line();
      previous_cell = false;
      continue;
    }
    const bool whitespace = code == L' ' || code == L'\t' || code == L'\u3000';
    if (!IsGridSupportedTextUnit(code))
      return Failure("grid_unsupported_text");
    if (IsGridCombiningMark(code) && previous_cell && !result.boxes.empty() &&
        result.boxes.back().text_position +
                result.boxes.back().text_length ==
            index) {
      result.boxes.back().text_length += length;
      index += length - 1;
      continue;
    }
    const double advance_ratio = CharacterAdvanceRatio(style, code);
    const double width_in_cells = advance_ratio;
    if (!std::isfinite(width_in_cells))
      return Failure("invalid_layout");

    constexpr double kCursorEpsilon = 1e-9;
    if (!hard_break && grid.trim_wrap_whitespace && whitespace &&
        (pending_wrap_space ||
         cursor_in_cells + width_in_cells >
             line_width_in_cells + kCursorEpsilon)) {
      pending_wrap_space = true;
      previous_cell = false;
      index += length - 1;
      continue;
    }
    if (pending_wrap_space) {
      advance_line();
      pending_wrap_space = false;
    }
    bool allow_hanging = false;
    if (!hard_break && cursor_in_cells + width_in_cells >
        line_width_in_cells + kCursorEpsilon) {
      allow_hanging =
          grid.hanging_punctuation &&
          cursor_in_cells + kCursorEpsilon >= line_width_in_cells &&
          !hanging_punctuation_used &&
          IsHangingPunctuation(code) &&
          cursor_in_cells + width_in_cells <=
              line_width_in_cells + 1.0 + kCursorEpsilon;
      if (!allow_hanging) {
        advance_line();
        if (cursor_in_cells + width_in_cells >
            line_width_in_cells + kCursorEpsilon) {
          // A continuation indent can leave less than one usable cell. Avoid
          // repeatedly wrapping an item that cannot fit on any line.
          allow_hanging =
              grid.hanging_punctuation &&
              cursor_in_cells + kCursorEpsilon >= line_width_in_cells &&
              !hanging_punctuation_used &&
              IsHangingPunctuation(code) &&
              cursor_in_cells + width_in_cells <=
                  line_width_in_cells + 1.0 + kCursorEpsilon;
          if (!allow_hanging && cursor_in_cells + width_in_cells >
                                   line_width_in_cells + kCursorEpsilon) {
            return Failure("grid_overflow_body_rect");
          }
        }
      }
    }
    RECT box{};
    const double left_in_cells = cursor_in_cells;
    if (!next_cell_bounds(left_in_cells, width_in_cells, &box))
      return Failure("grid_overflow_body_rect");
    cursor_in_cells += width_in_cells;
    if (allow_hanging) hanging_punctuation_used = true;
    if (!whitespace) {
      // Legacy punctuationVisualBounds remains readable for old profiles, but
      // actual per-character width is represented by the cell advance itself.
      result.boxes.push_back(ClusterBox{index, length, box, box});
    }
    previous_cell = !whitespace;
    index += length - 1;
  }
  if (result.boxes.empty()) return Failure("clusters_empty");
  return result;
}

// Build a surface-local layout. Runtime calibration is full-client; ordinary
// lookup is body-local except when a Hook hard break needs a glyph just beyond
// the saved body's right edge.
inline Result Build(IDWriteFactory *factory, const std::wstring &source,
                    const Layout &style, int client_height_px,
                    int surface_width_px, int surface_height_px,
                    const RECT &layout_bounds) {
  if (source.empty() || surface_width_px <= 0 || surface_height_px <= 0)
    return Failure("empty_text_or_no_surface_rect");
  if (!IsPunctuationVisualBoundsListValid(style) ||
      !IsCharacterAdvancesListValid(style))
    return Failure("invalid_layout");
  if (style.cell_grid.has_value()) {
    return BuildCellGrid(source, style, client_height_px, surface_width_px,
                         surface_height_px, layout_bounds);
  }
  if (factory == nullptr)
    return Failure("dwrite_factory_failed");
  constexpr float kMinimumBodyPixels = 8.0f;
  const float client_height = static_cast<float>(std::max(1, client_height_px));
  const float surface_width = static_cast<float>(surface_width_px);
  const float surface_height = static_cast<float>(surface_height_px);
  Result result;
  const float font_size = static_cast<float>(std::clamp(
      style.font_size_per_client_height * client_height, 1.0, 512.0));
  const float padding = static_cast<float>(
      std::max(0.0, style.padding_per_client_height * client_height));
  const float layout_width =
      static_cast<float>(layout_bounds.right - layout_bounds.left);
  const float layout_height =
      static_cast<float>(layout_bounds.bottom - layout_bounds.top);
  if (layout_width < kMinimumBodyPixels || layout_height < kMinimumBodyPixels) {
    return Failure("layout_bounds_too_small");
  }
  const float layout_origin_x =
      static_cast<float>(layout_bounds.left) + padding;
  const float layout_origin_y = static_cast<float>(layout_bounds.top) + padding;
  const float content_width = std::max(1.0f, layout_width - 2.0f * padding);
  const float content_height = std::max(1.0f, layout_height - 2.0f * padding);

  Microsoft::WRL::ComPtr<IDWriteTextFormat> format;
  HRESULT hr = factory->CreateTextFormat(
      style.font_family.c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, font_size, L"ja-JP",
      &format);
  if (FAILED(hr))
    return Failure("create_text_format_failed");
  if (style.text_align == "center") {
    format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
  } else if (style.text_align == "right" || style.text_align == "trailing") {
    format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_TRAILING);
  } else {
    format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
  }
  if (style.vertical_align == "center") {
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
  } else if (style.vertical_align == "bottom" ||
             style.vertical_align == "far") {
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_FAR);
  } else {
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
  }
  format->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
  const float line_spacing =
      std::max(font_size, font_size * static_cast<float>(style.line_height));
  // BUG-2138: Japanese ascenders can extend above the initial 0.8-em baseline.
  // Measure that overhang and lower the baseline by the actual amount before
  // validating the final layout. This preserves the runtime calibration rule.
  float baseline = font_size * 0.8f;
  {
    Microsoft::WRL::ComPtr<IDWriteTextFormat> probe_format;
    if (SUCCEEDED(factory->CreateTextFormat(
            style.font_family.c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, font_size,
            L"ja-JP", &probe_format))) {
      probe_format->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
      probe_format->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM,
                                   line_spacing, baseline);
      Microsoft::WRL::ComPtr<IDWriteTextLayout> probe_layout;
      if (SUCCEEDED(factory->CreateTextLayout(
              source.data(), static_cast<UINT32>(source.size()),
              probe_format.Get(), content_width, content_height,
              &probe_layout))) {
        DWRITE_OVERHANG_METRICS probe{};
        if (SUCCEEDED(probe_layout->GetOverhangMetrics(&probe)) &&
            probe.top > 0.0f) {
          baseline += probe.top;
        }
      }
    }
  }
  format->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, line_spacing,
                         baseline);

  hr = factory->CreateTextLayout(
      source.data(), static_cast<UINT32>(source.size()), format.Get(),
      content_width, content_height, &result.text_layout);
  if (FAILED(hr) || result.text_layout == nullptr)
    return Failure("create_text_layout_failed");

  const float letter_spacing = static_cast<float>(
      style.letter_spacing_per_client_height * client_height);
  if (letter_spacing != 0.0f) {
    Microsoft::WRL::ComPtr<IDWriteTextLayout1> layout1;
    if (SUCCEEDED(result.text_layout.As(&layout1))) {
      const DWRITE_TEXT_RANGE range{0, static_cast<UINT32>(source.size())};
      layout1->SetCharacterSpacing(letter_spacing * 0.5f, letter_spacing * 0.5f,
                                   0.0f, range);
    }
  }

  // A catch surface must never publish geometry for text that DirectWrite
  // clipped. A partially laid-out sentence makes the final visible glyphs map
  // to stale/absent boxes, which is worse than reporting no surface. Validate
  // all three views of the layout before exposing a single HWND region.
  constexpr float kLayoutEpsilon = 0.01f;
  DWRITE_TEXT_METRICS text_metrics{};
  if (FAILED(result.text_layout->GetMetrics(&text_metrics)) ||
      text_metrics.left < -kLayoutEpsilon ||
      text_metrics.top < -kLayoutEpsilon ||
      text_metrics.left + text_metrics.widthIncludingTrailingWhitespace >
          content_width + kLayoutEpsilon ||
      text_metrics.top + text_metrics.height >
          content_height + kLayoutEpsilon) {
    return Failure("metrics_overflow_body_rect");
  }
  DWRITE_OVERHANG_METRICS overhang{};
  if (FAILED(result.text_layout->GetOverhangMetrics(&overhang)) ||
      overhang.left > kLayoutEpsilon || overhang.top > kLayoutEpsilon ||
      overhang.right > kLayoutEpsilon || overhang.bottom > kLayoutEpsilon) {
    return Failure("overhang_outside_body_rect");
  }

  UINT32 line_count = 0;
  HRESULT line_hr = result.text_layout->GetLineMetrics(nullptr, 0, &line_count);
  if ((line_hr != E_NOT_SUFFICIENT_BUFFER && FAILED(line_hr)) ||
      line_count == 0) {
    return Failure("line_metrics_unavailable");
  }
  std::vector<DWRITE_LINE_METRICS> lines(line_count);
  line_hr =
      result.text_layout->GetLineMetrics(lines.data(), line_count, &line_count);
  if (FAILED(line_hr)) {
    return Failure("line_metrics_read_failed");
  }
  uint64_t line_units = 0;
  double line_height_total = 0.0;
  for (UINT32 index = 0; index < line_count; ++index) {
    if (lines[index].isTrimmed) {
      return Failure("line_trimmed");
    }
    line_units += lines[index].length;
    line_height_total += lines[index].height;
  }
  if (line_units != source.size() ||
      line_height_total > content_height + kLayoutEpsilon) {
    return Failure("line_units_or_height_mismatch");
  }

  UINT32 cluster_count = 0;
  hr = result.text_layout->GetClusterMetrics(nullptr, 0, &cluster_count);
  if (hr != E_NOT_SUFFICIENT_BUFFER && FAILED(hr))
    return Failure("cluster_metrics_unavailable");
  if (cluster_count == 0)
    return Failure("cluster_count_zero");
  std::vector<DWRITE_CLUSTER_METRICS> metrics(cluster_count);
  hr = result.text_layout->GetClusterMetrics(metrics.data(), cluster_count,
                                             &cluster_count);
  if (FAILED(hr))
    return Failure("cluster_metrics_read_failed");

  uint32_t text_position = 0;
  for (UINT32 index = 0; index < cluster_count; ++index) {
    const DWRITE_CLUSTER_METRICS &cluster = metrics[index];
    const uint32_t length = cluster.length;
    if (length == 0 || text_position >= source.size() ||
        static_cast<uint64_t>(text_position) + length > source.size()) {
      return Failure("cluster_range_out_of_text");
    }
    if (!cluster.isWhitespace && !cluster.isNewline && !cluster.isSoftHyphen) {
      UINT32 hit_count = 0;
      HRESULT hit_hr = result.text_layout->HitTestTextRange(
          text_position, length, layout_origin_x, layout_origin_y, nullptr, 0,
          &hit_count);
      if ((hit_hr != E_NOT_SUFFICIENT_BUFFER && FAILED(hit_hr)) ||
          hit_count == 0) {
        return Failure("hit_test_range_empty");
      }
      std::vector<DWRITE_HIT_TEST_METRICS> hits(hit_count);
      hit_hr = result.text_layout->HitTestTextRange(
          text_position, length, layout_origin_x, layout_origin_y, hits.data(),
          hit_count, &hit_count);
      if (FAILED(hit_hr)) {
        return Failure("hit_test_range_failed");
      }
      for (UINT32 hit_index = 0; hit_index < hit_count; ++hit_index) {
        const DWRITE_HIT_TEST_METRICS &hit = hits[hit_index];
        RECT box{
            static_cast<LONG>(std::floor(hit.left)),
            static_cast<LONG>(std::floor(hit.top)),
            static_cast<LONG>(std::ceil(hit.left + hit.width)),
            static_cast<LONG>(std::ceil(hit.top + hit.height)),
        };
        if (!RectHasArea(box) || box.left < 0 || box.top < 0 ||
            box.right > static_cast<LONG>(surface_width) ||
            box.bottom > static_cast<LONG>(surface_height)) {
          return Failure("cluster_box_outside_surface");
        }
        result.boxes.push_back(
            ClusterBox{text_position, length, box, box});
      }
    }
    text_position += length;
  }
  if (text_position != source.size()) {
    return Failure("text_position_mismatch");
  }
  if (result.boxes.empty())
    return Failure("clusters_empty");
  return result;
}

// Bounded, stateless preview of the *configured runtime* catch geometry. Build
// relative to the body before adding the integer origin, matching runtime's
// rounding even when the body begins at a fractional normalized coordinate.
inline Result Preview(const std::wstring &source,
                      const ReferenceClient &reference,
                      const NormalizedRect &body_rect, const Layout &layout) {
  constexpr size_t kMaximumSourceTextUnits = 32768;
  constexpr int kMaximumClientExtent = 16384;
  constexpr int64_t kMaximumClientPixels = 64LL * 1024 * 1024;
  if (source.empty())
    return Failure("empty_text_or_no_surface_rect");
  if (source.size() > kMaximumSourceTextUnits)
    return Failure("source_text_too_large");
  if (reference.width_px <= 0 || reference.height_px <= 0 ||
      reference.width_px > kMaximumClientExtent ||
      reference.height_px > kMaximumClientExtent || reference.dpi <= 0 ||
      reference.dpi > 960 ||
      static_cast<int64_t>(reference.width_px) * reference.height_px >
          kMaximumClientPixels)
    return Failure("invalid_reference_client");
  if (!IsNormalizedRectValid(body_rect))
    return Failure("invalid_body_rect");
  if (layout.font_family.size() > 256 ||
      !attached_layout_validation::IsLayoutValid(
          layout.font_size_per_client_height,
          layout.letter_spacing_per_client_height, layout.line_height,
          layout.text_align, layout.vertical_align,
          layout.padding_per_client_height) ||
      (layout.cell_grid.has_value() && !IsCellGridValid(*layout.cell_grid)))
    return Failure("invalid_layout");
  if (!IsPunctuationVisualBoundsListValid(layout) ||
      !IsCharacterAdvancesListValid(layout))
    return Failure("invalid_layout");
  const RECT client{0, 0, reference.width_px, reference.height_px};
  const RECT body = ResolveBodyRect(client, body_rect);
  const int width = body.right - body.left;
  const int height = body.bottom - body.top;
  const RECT bounds{0, 0, width, height};
  Microsoft::WRL::ComPtr<IDWriteFactory> factory;
  if (FAILED(DWriteCreateFactory(
          DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
          reinterpret_cast<IUnknown **>(factory.GetAddressOf()))))
    return Failure("dwrite_factory_failed");
  Layout style = layout;
  if (style.font_family.empty())
    style.font_family = L"Yu Gothic";
  // Hard-break cells can extend past the selected rectangle, but never past
  // the source client. Preview and runtime must use the same physical limit.
  const bool hard_break = UsesHookLineBreaks(source, style);
  const int surface_width = hard_break ? reference.width_px - body.left : width;
  const int surface_height =
      style.cell_grid.has_value() && style.cell_grid->explicit_line_breaks
          ? reference.height_px - body.top
          : height;
  Result result = Build(factory.Get(), source, style, reference.height_px,
                        surface_width, surface_height, bounds);
  for (ClusterBox &box : result.boxes) {
    box.hit_rect.left += body.left;
    box.hit_rect.right += body.left;
    box.hit_rect.top += body.top;
    box.hit_rect.bottom += body.top;
    box.visual_rect.left += body.left;
    box.visual_rect.right += body.left;
    box.visual_rect.top += body.top;
    box.visual_rect.bottom += body.top;
  }
  return result;
}

} // namespace fushi::attached_text_layout

#endif // RUNNER_ATTACHED_TEXT_LAYOUT_H_
