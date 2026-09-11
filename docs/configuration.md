# Configuration

## Working directory

Use `-C <dir>` (or `-C=<dir>`) to run the command in another working directory:

```sh
fb -C ./project 'zig build'
FILE_BASH_CWD=./project fb 'zig build'
```

`-C` overrides `FILE_BASH_CWD`. An unset or empty environment value inherits
`fb`'s working directory. Relative paths resolve from where `fb` was invoked;
paths containing spaces are supported when quoted. An empty `-C` is an argument
error. The directory is opened before saving output, so a missing or
inaccessible directory fails without running the command or overwriting a named
run. This setting applies only to `run` and does not change where output is
saved.

## Shell

Shell source is executed by `sh -c` on Linux and macOS and by `cmd.exe /d /s /c`
on Windows. Set `FILE_BASH_SHELL` to select another command interpreter.
Supported values are `sh`, `bash`, `zsh`, `fish`, `nu`, `cmd`, `powershell`, and
`pwsh`.

```sh
FILE_BASH_SHELL=fish fb 'echo hello'
```

An unset or empty value uses the platform default. An unknown value is an error.
`cmd` and `powershell` are available only on Windows; `pwsh` is cross-platform.
The selected shell must be available on `PATH`.

## Output size limit

`run` measures the `stdout` and `stderr` files every 20 ms while the command
runs. If either file exceeds the limit, the command is killed with `SIGKILL`,
the run reports which stream grew too large, and `fb` exits with 153, matching
a shell's report of `SIGXFSZ`. This stops a looping command from filling the
disk before a timeout fires. Output written before the kill stays in the files.

The default limit is 256M per file. Set `FILE_BASH_MAX_SIZE` to change it:

```sh
FILE_BASH_MAX_SIZE=1G fb 'zig build test'
FILE_BASH_MAX_SIZE=4096 fb 'make'
```

The value is a positive integer with an optional `K`, `M`, or `G` suffix
(powers of 1024); a bare integer means bytes. An unset or empty value uses the
default; any other invalid value is an error and the command does not run.

Pass `--unlimited` (short form `-u`) to disable the limit for one run, for
example when a command is expected to produce huge output and must not be
interrupted. On Linux and macOS a limited run leads its own process group like a
timed run does, so the kill reaches the whole command tree; `--unlimited`
without `--timeout` keeps the command in `fb`'s process group.

## Temporary directory

Linux and macOS use `TMPDIR`, falling back to `/tmp`. Windows checks `TMP`, then
`TEMP`, and reports an error if neither is set. Empty values are skipped;
relative paths are rejected, and the selected temporary directory must already
exist. `run` and `clean` use the same lookup.

## Child environment

The child inherits the parent environment, then `fb` overrides these variables
to discourage prompts, paging, and colored output:

- All platforms: `NO_COLOR=1`, `CLICOLOR=0`, and `GIT_TERMINAL_PROMPT=0`
- Linux and macOS: `TERM=dumb`, `PAGER=cat`, and `GIT_PAGER=cat`
- Linux: `DEBIAN_FRONTEND=noninteractive`

These values replace any inherited values.
