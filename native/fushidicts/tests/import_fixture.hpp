// Shared "zip the fixture files, import them, hand back the dictionary dir"
// step for fushidicts native e2e tests that need a real imported dictionary.
// Kept apart from zip_fixture.hpp because it pulls in the importer: tests that
// only build zips do not have to link against it.
#pragma once

#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "zip_fixture.hpp"

namespace fushi_test {

// Writes [files] as the STORED zip [zip_name], imports it into [out_dir] and
// returns the imported dictionary directory. On failure returns "" and puts the
// reason into [error].
inline std::string import_fixture_dict(const std::string& zip_name, const std::vector<ZipFile>& files,
                                       const std::string& out_dir, std::string& error) {
  const std::string zip_path = write_zip(zip_name.c_str(), files);
  if (zip_path.empty()) {
    error = "could not write fixture zip";
    return {};
  }
  const ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    error = "import: " + (r.errors.empty() ? std::string("(no error)") : r.errors.front());
    return {};
  }
  return out_dir + "/" + r.title;
}

}  // namespace fushi_test
