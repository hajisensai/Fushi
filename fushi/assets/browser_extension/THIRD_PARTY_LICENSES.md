# Third-party licenses

## asbplayer

Portions of `stream-bridge.js` and the associated streaming-site adapters are
derived from asbplayer:

- Source: https://github.com/asbplayer/asbplayer
- Upstream files: `extension/src/entrypoints/*-page.ts`
- License: MIT

MIT License

Copyright (c) 2020-2026 asbplayer authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Material Symbols (Rounded)

The icon glyph paths in `icons.js` are a subset of Google's Material Symbols
Rounded (weight 400, FILL 0), taken verbatim from the `@material-symbols/svg-400`
package (`rounded/<name>.svg`).

- Source: https://github.com/google/material-design-icons
- License: Apache License, Version 2.0
- License text: https://www.apache.org/licenses/LICENSE-2.0

Copyright 2022 Google LLC. Licensed under the Apache License, Version 2.0 (the
"License"); you may not use these files except in compliance with the License.
Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.

## material_color_utilities

`material-color.js` is a line-by-line JavaScript port of the subset of Google's
material_color_utilities (Dart package 0.13.0, the version pinned by the Flutter
SDK) needed to generate Material 3 dynamic color schemes from a seed color: HCT /
CAM16, tonal palettes, dislike analyzer, temperature cache, contrast, dynamic
colors and all scheme variants.

- Source: https://github.com/material-foundation/material-color-utilities
- Upstream files: `dart/lib/{utils,hct,palettes,dislike,temperature,contrast,dynamiccolor,scheme}/**`
- License: Apache License, Version 2.0
- License text: https://www.apache.org/licenses/LICENSE-2.0

Copyright 2021 Google LLC. Licensed under the Apache License, Version 2.0 (the
"License"); you may not use these files except in compliance with the License.
Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.
