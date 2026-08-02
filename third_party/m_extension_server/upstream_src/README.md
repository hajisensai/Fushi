# M-Extension-Server — headless Mihon (Tachiyomi)/Aniyomi extensions server

M-Extension-Server is a lightweight, headless service for running Mihon (Tachiyomi)/Aniyomi extensions (APKs). It dynamically loads extensions from Base64-encoded APKs, executes catalogue and content methods (manga/anime), and returns results via a small HTTP API.

## Mangatan compatibility

The `v1.0.4.1` release adds the bridge protocol used by Mangatan for
factory-created sources and live extension preferences. A compatible server
advertises `mangatanMihonBridge`, `sourceFactory`, `preferenceCallbacks`,
`sourceUrls`, and `imageProxy` from `GET /capabilities`.

The manga bridge implements the TachiyomiX 1.6 source API, including combined
manga updates, source memo metadata, and suspend image URL resolution. Legacy
RxJava extensions continue to work through compatibility fallbacks.

## Credits

The `AndroidCompat` module was originally developed by [@null-dev](https://github.com/null-dev) for [TachiWeb-Server](https://github.com/Tachiweb/TachiWeb-server) and is licensed under `Apache License Version 2.0`.

Parts of [Mihon (Tachiyomi)](https://github.com/mihonapp/mihon) is adopted into this codebase, also licensed under `Apache License Version 2.0`.

Parts of [Aniyomi](https://github.com/aniyomiorg/aniyomi) is adopted into this codebase, also licensed under `Apache License Version 2.0`.

You can obtain a copy of `Apache License Version 2.0` from  http://www.apache.org/licenses/LICENSE-2.0

Changes to both codebases is licensed under `MPL 2.0` as the rest of this project.

## License

```
Copyright © 2024 Aniyomi Open Source Project

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
```

```
Copyright © 2024 Mihon Open Source Project

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
```

```
Copyright (C) Contributors to the Suwayomi project

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
```
