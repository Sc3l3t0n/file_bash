# file_bash

`fb` runs a shell command and saves standard output and standard error to
separate files. It reports their paths, sizes, and the command's exit code, so
long or noisy commands stay easy to inspect.

## Install

Clone this repository, then build from its directory with Zig 0.16.0 or newer:

```sh
zig build -Doptimize=ReleaseFast
```

Add `zig-out/bin` to your `PATH`, or copy `zig-out/bin/fb` to a directory that
is already on it. The Windows executable is `zig-out/bin/fb.exe`.

## Use

Pass a quoted shell command to `fb`:

```sh
fb 'echo hello; echo error >&2; exit 7'
fb run --tail 20 'zig build test'
fb last
fb print build
fb clean
```

`run` is the default command. Commands run through `sh` on Linux and macOS and
`cmd.exe` on Windows unless configured otherwise. Run `fb --help` or
`fb run --help` for the complete command-line reference.

## Documentation

- [Usage](docs/usage.md)
- [Configuration](docs/configuration.md)
- [Agent instructions](docs/agent-instructions.md)

## AI/LLM disclosure

AI/LLMs assisted with development. I reviewed all code and remain responsible
for all of it.
