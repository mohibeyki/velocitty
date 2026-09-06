# Third-party notices

This is the consolidated third-party provenance and license notice for Velocitty
and VeloKit.
VeloKit's own license is in [LICENSE](LICENSE). Dependency source trees may
also contain their original license files; those files stay with the code they
govern, while this document is the project-level notice.

## libghostty-derived source

VeloKit includes a locally maintained fork of the libghostty terminal engine
and its macOS embedding layer. The retained source originated from:

- Project: [libghostty source repository](https://github.com/ghostty-org/ghostty)
- Revision: `492300cad104195411d12217dd22f1cd05f31376`
- Commit date: 2026-09-04
- Imported: 2026-09-05
- Upstream package version: `1.3.2-dev`
- Zig version: `0.16.0`
- Source archive: https://codeload.github.com/ghostty-org/ghostty/tar.gz/492300cad104195411d12217dd22f1cd05f31376
- Archive SHA-256: `12ff0ed206e42049433c2afbacfd9656d568241e482e718b930868915e21cb93`

The original MIT notice for the retained source is reproduced below.

### MIT License — libghostty-derived source

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

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

## zig-afl-kit

VeloKit retains the following notice for the AFL++ helper package:

Based on zig-afl-kit: https://github.com/kristoff-it/zig-afl-kit

MIT License

Copyright (c) 2024 Loris Cro

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

## Other dependencies

VeloKit vendors and fetches additional dependencies under their respective
licenses. Their license texts and notices remain with their source under
`pkg/` and `zig-pkg/`; this file is the consolidated index for distribution.

## TOMLDecoder

The macOS configuration parser uses [TOMLDecoder](https://github.com/dduan/TOMLDecoder),
version 0.4.5 (revision `a2bbd2796fe3064e107de18cb56031052c4fa899`).
Its MIT license is reproduced below.

```text
The MIT License (MIT)

Copyright (c) 2019 TOMLDecoder contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
