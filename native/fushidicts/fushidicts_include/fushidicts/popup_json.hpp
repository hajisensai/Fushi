#pragma once

#include <string>
#include <vector>

#include "lookup.hpp"

std::string build_popup_json(const std::vector<LookupResult>& results,
                             int max_terms);
