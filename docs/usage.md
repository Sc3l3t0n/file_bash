# Usage

Run `fb`, `fb -h`, or `fb --help` for general help. Run `fb run --help`
(also `fb run` or `fb run -h`) for run options and examples. General help
lists commands without listing run options. Help exits successfully without
running a shell command or creating output files.

## Running commands

`run` is the default command. If the first argument matches a command name, it
selects that command; otherwise it is passed to `run`. An explicit `run` treats
the next argument as shell source, even if it matches a command name.

Quote the entire command. A second command argument is an error. Standard input
is inherited.

```sh
fb 'echo hello; echo error >&2; exit 7'
fb run 'echo hello'
```

The runner prints the absolute paths to separate `stdout` and `stderr` files in
a unique directory under `file_bash/` in the temporary directory. Once the
command finishes, it also prints each file's size in bytes and the exit code.
Output goes directly to the files while the command runs, and the files remain
until you remove them or the system cleans its temporary directory.

With `--async` (short form `-a`), paths are printed before the command starts so
the files can be followed while it runs. File sizes are always printed after
the command finishes, after any requested excerpts.

## Named and recent runs

Use `--name <name>` (or `-n`, also `--name=<name>`) to choose a stable run
directory such as `/tmp/file_bash/build/`:

```sh
fb run --name build 'zig build'
```

Names contain 1–64 ASCII letters, digits, hyphens, or underscores. `last` is
reserved case-insensitively. Windows binaries also reserve device names.
Reusing a name overwrites its stdout, stderr, and completion status. Wait for a
named run to finish before reusing its name. Unnamed runs use random IDs.
`fb last`, `fb print`, and `fb clean` also work with named runs.

Run `fb last` to report the latest run's output again without rerunning the
command. `fb last --help` explains this behavior and where the run ID is stored.
It accepts `--json` and all head/tail options supported by `run`, including
per-stream options and short aliases. Each invocation uses its own excerpt
options rather than reusing the original run's settings.

```sh
fb last --tail 20
fb last --json --out:head 3 --err:tail 10
```

Run `fb print [options] <id>` to report any saved run by its ID. It accepts the
same JSON and excerpt options as `last`, returns the saved command's exit code,
and does not rerun the command or change which run `last` selects.

```sh
fb print --tail 20 build
fb print --json 0123456789abcdef0123456789abcdef
```

Each run writes only its ID to `file_bash/last` after successfully starting the
shell. A failed start leaves the previous run ID unchanged. The run directory
retains stdout, stderr, and a two-byte `status` file containing the exit code and
timeout flag. `run`, `last`, and `print` build reports from these files and return the
command's exit code. Overlapping runs select the most recently started run. If
no run is saved or its completion status is unavailable, `last` reports an
error and returns 1.

Run `fb clean` to remove all children of the temporary `file_bash` directory,
including every run's output, completion status, and the `last` file, while
keeping the directory itself. It succeeds if `file_bash` is already absent.
Stop running commands before cleaning their output. Use `fb clean --help` (or
`-h`) for help.

## Output excerpts

`--head <n>` and `--tail <n>` (short `-d`, `-l`) print the first or last `n`
lines of both output files after the command exits, each under a marker line.
`--out:head`, `--out:tail`, `--err:head`, and `--err:tail` (short `-o:h`,
`-o:l`, `-e:h`, `-e:l`) restrict this to one file.

For each of head and tail, use either its general flag for both files or its
individual flags. Combining `--head` with `--out:head` or `--err:head`, or
`--tail` with `--out:tail` or `--err:tail`, is an error in either order. Either
individual flag can be used alone, or both can be used with different counts.
Head and tail are independent, so `--head 3 --err:tail 10` is valid.

```sh
fb run --tail 20 'zig build test'
fb run -o:l 5 -e:l=50 'make'
```

## JSON output

`--json` prints one JSON object on completion instead of the text report. It
cannot be combined with `--async`. Both streams contain `path` and `size` in
bytes, plus `head` and/or `tail` when requested. The result includes `exit_code`
and `timed_out`; `fb` still returns the command's exit code. Diagnostics go to
stderr.

```sh
fb run --json --head 3 'echo hello'
```

Excerpts keep the text style's final newline. Paths and excerpts are always JSON
strings: valid UTF-8 is preserved, and invalid bytes become `\u00XX` escapes.
These escapes map bytes to Unicode characters for display rather than providing
a lossless binary encoding. Both output styles stream excerpts without
buffering the entire value. The saved files always retain the original bytes.

## Timeouts and exit codes

`--timeout <duration>` kills a command that runs too long. `-t` is the short
form, and both accept a separate value or `=`:

```sh
fb run --timeout 30s 'zig build'
fb run -t 500ms 'sleep 5'
fb run -t=2m 'zig build test'
```

The duration is a positive count with an `ms`, `s`, `m`, or `h` suffix; a bare
count means seconds. A timed command is killed with `SIGKILL` once the duration
elapses, reports the timeout on stderr, and exits with 124, matching
`timeout(1)`. Output written before the kill stays in the files. On Linux and
macOS, the command leads its own process group and the whole group is killed.
On Windows, only the shell process is terminated. Without `--timeout`, the
command runs unbounded and keeps receiving the terminal's signals.

The runner returns the command's exit code, or 128 plus the signal capped at
255 when terminated by a signal. Missing or invalid arguments return 2; runner
errors return 1.

Print the program version with `fb --version` or `fb -v`.
