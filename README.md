# file_bash

Run a shell command and save its output to files:

```sh
zig build
./zig-out/bin/fb 'echo hello; echo error >&2; exit 7'
./zig-out/bin/fb run 'echo hello'
```

`run` is the default command. If the first
argument matches a command name, it selects that command; otherwise it is
passed to `run`. An explicit `run` treats the next argument as shell source,
even if it matches a command name.

The shell source is executed by `sh -c` on Linux/macOS and
`cmd.exe /d /s /c` on Windows. Quote the entire command; a second command
argument is an error. Standard input is inherited.

Set `FILE_BASH_SHELL` to select another command interpreter. Supported values
are `sh`, `bash`, `zsh`, `fish`, `nu`, `cmd`, `powershell`, and `pwsh`. For
example:

```sh
FILE_BASH_SHELL=fish ./zig-out/bin/fb 'echo hello'
```

An unset or empty value uses the platform default described above. An unknown
value is an error. `cmd` and `powershell` are available only on Windows; `pwsh`
is cross-platform. The selected shell must be available on `PATH`.

The runner prints the absolute paths to separate `stdout` and `stderr` files in a
unique `file_bash-*` directory under the temporary directory before the command
starts, so the files can be followed while it runs, and prints the exit code once
it finishes.
Linux/macOS use `TMPDIR`, falling back to `/tmp`. Windows checks `TMP`, then `TEMP`,
and reports an error if neither is set. Empty values are skipped; relative
paths are rejected, and the selected temporary directory must already exist.
Output goes directly to
the files while the command runs. Files remain after exit until you remove them
or the system cleans its temporary directory.

The child runs with a non-interactive environment: fb inherits the parent
environment and then overrides `NO_COLOR=1`, `CLICOLOR=0`, and
`GIT_TERMINAL_PROMPT=0` everywhere, plus `TERM=dumb`, `PAGER=cat`, and
`GIT_PAGER=cat` on Linux/macOS and `DEBIAN_FRONTEND=noninteractive` on Linux.
These overrides win over inherited values, so commands do not wait for a prompt
or write escape sequences into the output files.

`--timeout <duration>` kills the command when it runs too long. `-t` is the
short form, and both accept the value as a separate argument or after `=`:

```sh
fb run --timeout 30s 'zig build'
fb run -t 500ms 'sleep 5'
fb run -t=2m 'zig build test'
```

The duration is a positive count with a `ms`, `s`, `m`, or `h` suffix; a bare
count means seconds. A timed command is killed with `SIGKILL` once the duration
elapses, the runner reports the timeout on stderr, and the exit code is 124,
matching `timeout(1)`. Output written before the kill stays in the files.
On Linux/macOS a timed command leads its own process group and the whole group
is killed, so descendant processes do not survive the timeout; on Windows only
the shell process is terminated. Without `--timeout` the command runs
unbounded and keeps receiving the terminal's signals.

The runner returns the command's exit code (or 128 + signal, capped at 255, when
terminated by a signal). Missing or invalid arguments return 2; runner errors
return 1.

Install minimal fb instructions globally (ensure `fb` is on `PATH`):

```sh
fb install          # ~/.agents/AGENTS.md (same as: fb install agents)
fb install claude   # ~/.claude/CLAUDE.md
fb uninstall        # remove the fb section from AGENTS.md
fb uninstall claude # remove the fb section from CLAUDE.md
```

`init` is an alias for `install`, including `fb init claude`.

Only global installation is supported. Home lookup uses `HOME` on Unix and
`USERPROFILE` on Windows. Missing, empty, or relative home paths are errors.

Install creates missing directories and files, and adds or updates a section
between `<!-- fb:begin -->` and `<!-- fb:end -->`. Uninstall removes only that
section, preserving surrounding content and leaving the file in place. Repeated
installs/uninstalls are safe; malformed or duplicate markers produce an error
without modifying the file.

Print the program version:

```sh
fb version
```

## AI disclosure

AI/LLMs assisted with development. I reviewed all code and remain responsible for all of it.
