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
