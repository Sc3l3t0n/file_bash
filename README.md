# file_bash

Run a shell command and save its output to files:

```sh
zig build
./zig-out/bin/file_bash 'echo hello; echo error >&2; exit 7'
```

The first argument is executed by `/bin/sh -c`. Quote the entire command;
additional arguments are ignored. Standard input is inherited.

The runner prints the exit code and absolute paths to separate `stdout` and
`stderr` files in a unique `/tmp/file_bash-*` directory. Output goes directly to
the files while the command runs. Files remain after exit until you remove them
or the system cleans its temporary directory.

The runner returns the command's exit code (or 128 + signal, capped at 255, when
terminated by a signal). Missing arguments return 2; runner errors return 1.
