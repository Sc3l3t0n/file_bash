# TODO

Ideas gathered from using `fb` as an agent, ordered by expected impact.

## Save the follow-up read

- [x] `--tail N` / `--head N`: print the last or first N lines of each file inline
      after the exit code. Most runs are short or fail near the end.
- [x] Print line and byte counts per file, and state when stderr is empty, so the
      agent knows whether to `cat` or `grep`.
- [ ] Print the duration, to judge whether a timeout was reasonable.
- [x] `--json` summary line: paths, exit code, counts, duration.

## Predictable paths and cleanup

- [x] `--name <name>`: write to a stable directory such as `/tmp/file_bash/<name>/`.
      Reruns overwrite; the path can be referenced without parsing output.
- [x] `fb last`: print the paths of the most recent run.
- [x] `fb clean`: remove old `file_bash-*` run directories.
- [ ] further customization to `fb clean` like `--until` or `--since`

## Buffering (blocks "read while running")

- [ ] Set `PYTHONUNBUFFERED=1`; Python and .NET fully buffer when stdout is a file.
- [ ] `--line-buffered` on Linux via `stdbuf -oL` or a pty for C/Rust tools.
- [ ] Add `CI=1`, `DOTNET_NOLOGO=1`, `DOTNET_CLI_TELEMETRY_OPTOUT=1`, unset
      `FORCE_COLOR`, and set `COLUMNS=200` so build tools do not wrap lines.

## Safety for unattended use

- [x] `--stdin=null` (or close stdin by default): a command waiting on stdin hangs
      an agent silently.
- [ ] Per-file size cap with a truncation notice, so a looping process cannot fill
      the disk before the timeout fires.
- [x] `-C <dir>`: set the working directory instead of `cd` in the command.

## Optional

- [ ] `--merge`: single interleaved stdout/stderr file; order between streams
      matters when diagnosing build output.
- [ ] `--quiet`: on exit 0 with empty stderr print only the exit code line.
