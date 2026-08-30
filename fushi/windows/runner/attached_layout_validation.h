#ifndef RUNNER_ATTACHED_LAYOUT_VALIDATION_H_
#define RUNNER_ATTACHED_LAYOUT_VALIDATION_H_

#include <cmath>
#include <string_view>

namespace fushi::attached_layout_validation {

inline bool IsLayoutValid(double font_size_per_client_height,
                          double letter_spacing_per_client_height,
                          double line_height, std::string_view text_align,
                          std::string_view vertical_align,
                          double padding_per_client_height) {
  const bool horizontal_alignment =
      text_align == "left" || text_align == "center" || text_align == "right";
  const bool vertical_alignment = vertical_align == "top" ||
                                  vertical_align == "center" ||
                                  vertical_align == "bottom";
  return std::isfinite(font_size_per_client_height) &&
         font_size_per_client_height > 0.0 &&
         font_size_per_client_height <= 0.5 &&
         std::isfinite(letter_spacing_per_client_height) &&
         letter_spacing_per_client_height >= -0.05 &&
         letter_spacing_per_client_height <= 0.1 &&
         std::isfinite(line_height) && line_height >= 0.5 &&
         line_height <= 4.0 && horizontal_alignment && vertical_alignment &&
         std::isfinite(padding_per_client_height) &&
         padding_per_client_height >= 0.0 && padding_per_client_height <= 0.25;
}

} // namespace fushi::attached_layout_validation

#endif // RUNNER_ATTACHED_LAYOUT_VALIDATION_H_
