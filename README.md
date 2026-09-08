# file_bash

Run a shell command and save its output to files:

```sh
zig build
./zig-out/bin/fb 'echo hello; echo error >&2; exit 7'
```

The first argument is executed by `sh -c` on Linux/macOS and
`cmd.exe /d /s /c` on Windows. Quote the entire command;
additional arguments are ignored. Standard input is inherited.

Set `FILE_BASH_SHELL` to select another command interpreter. Supported values
are `sh`, `bash`, `zsh`, `fish`, `nu`, `cmd`, `powershell`, and `pwsh`. For
example:

```sh
FILE_BASH_SHELL=fish ./zig-out/bin/fb 'echo hello'
```

An unset or empty value uses the platform default described above. An unknown
value is an error. `cmd` and `powershell` are available only on Windows; `pwsh`
is cross-platform. The selected shell must be available on `PATH`.

The runner prints the exit code and absolute paths to separate `stdout` and
`stderr` files in a unique `file_bash-*` directory under the temporary directory.
Linux/macOS use `TMPDIR`, falling back to `/tmp`. Windows checks `TMP`, then `TEMP`,
and reports an error if neither is set. Empty values are skipped; relative
paths are rejected, and the selected temporary directory must already exist.
Output goes directly to
the files while the command runs. Files remain after exit until you remove them
or the system cleans its temporary directory.

The runner returns the command's exit code (or 128 + signal, capped at 255, when
terminated by a signal). Missing arguments return 2; runner errors return 1.
