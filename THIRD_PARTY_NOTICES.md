# Third-Party Notices

TAX is licensed under the MIT license (see `LICENSE`). This file covers bundled
third-party material and the Orca integration, which is not bundled.

## App Icon

The TAX App Icon (`ios/tax/tax/Assets.xcassets/AppIcon.appiconset/AppIcon.png`)
is an original work created for this project. The project owner has confirmed
the right to distribute it under the project license.

## Fonts

Two typeface families are bundled in the iOS app. Each is distributed under the
SIL Open Font License, Version 1.1, and the complete license text is kept next
to the font files:

- **JetBrains Mono** (`JetBrainsMono-Regular.ttf`, `JetBrainsMono-Medium.ttf`)
  — Copyright 2020 The JetBrains Mono Project Authors
  (<https://github.com/JetBrains/JetBrainsMono>). License:
  `ios/tax/tax/Resources/Fonts/JetBrainsMono-OFL.txt`.
- **Space Grotesk** (`SpaceGrotesk-Regular.ttf`, `SpaceGrotesk-Medium.ttf`,
  `SpaceGrotesk-SemiBold.ttf`) — Copyright 2020 The Space Grotesk Project
  Authors (<https://github.com/floriankarsten/space-grotesk>). License:
  `ios/tax/tax/Resources/Fonts/SpaceGrotesk-OFL.txt`.

## SwiftTerm

The iOS app uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
version **1.20.0** (pinned as an exact-version Swift Package Manager
dependency, not vendored) as the terminal renderer. SwiftTerm is licensed
under the MIT license with the following copyright notice:

```text
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)
```

```text
Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Orca integration

TAX integrates with the user's locally installed Orca app through TAX-owned
code only: `src/tax/orca_runtime.py` (Mac-side adapter) and
`src/tax/resources/orca-runtime-terminal-bridge.cjs` (terminal bridge). No Orca
source code, modules, or assets are bundled with, extracted into, or
redistributed by TAX. At runtime the bridge and the probe script load Orca
protocol helpers directly from the user's own installed Orca build; a missing
helper or an incompatible wire contract produces an explicit compatibility
failure. See `docs/orca-runtime-compatibility.md` for the compatibility
contract.
