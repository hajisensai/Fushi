#pragma once

#include <algorithm>
#include <string>

namespace hoshidicts {

inline std::string normalize_media_path(std::string path) {
  std::ranges::replace(path, '\\', '/');
  while (!path.empty() && path.front() == '/') {
    path.erase(path.begin());
  }
  return path;
}

}
