cmake_minimum_required(VERSION 3.13)
project(fushi_lookup_card LANGUAGES CXX)

# App-external global lookup card process (card_overlay.h). Links only system
# libraries: GTK 3, WebKitGTK 4.1, json-glib, Xlib + XInput2.
add_executable(fushi_lookup_card
  "main.cc"
  "card_overlay.cc"
)
target_compile_features(fushi_lookup_card PRIVATE cxx_std_17)
target_compile_options(fushi_lookup_card PRIVATE -Wall -Wextra -Werror)
target_compile_definitions(fushi_lookup_card PRIVATE
  "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
target_link_libraries(fushi_lookup_card PRIVATE
  PkgConfig::GTK PkgConfig::LOOKUP_CARD)
