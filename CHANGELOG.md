# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-11

First usable release. `fb` runs a shell command, writes stdout and stderr to
separate files, and prints a compact report so long or noisy output stays easy
to inspect. Aimed at coding agents, but works for humans too.

### Added

- `fb run` (default command) captures stdout and stderr into
  `/tmp/file_bash/<id>/` and prints the paths, sizes, exit code, and duration.
- `--tail <n>` / `-l` and `--head <n>` / `-d` print the last or first n lines of
  both files inline. `--out:tail`, `--out:head`, `--err:tail`, and `--err:head`
  target one stream. Mixing head and tail options is rejected.
- `--timeout <duration>` / `-t` kills the command when it runs too long.
- `--async` prints the file paths before the command finishes so they can be
  read while it runs.
- `--name <name>` / `-n` writes to a stable directory, `/tmp/file_bash/<name>/`.
  Reruns overwrite the previous output.
- Named runs hold a `lock` file while running. Reusing the name fails with exit
  code 1 and reports the lock age. `--overwrite` forces the reuse when the lock
  is known to be stale.
- `-C <dir>` sets the working directory for the command; `FILE_BASH_CWD`
  provides a default.
- `--json` emits the report as one JSON line.
- `fb last` reprints the report of the most recent run.
- `fb print <id>` reprints the report of any saved run by ID or name.
- `fb clean` removes all saved run directories.
- `fb install [agents|claude]` (alias: `init`) and `fb uninstall` manage a global
  `fb` section in `~/.agents/AGENTS.md` or `~/.claude/CLAUDE.md`. Edits are
  reversible and idempotent.
- Per-file output size limit (default 256M) kills the command before it fills
  the disk. Configure with `FILE_BASH_MAX_SIZE`, disable with `--unlimited`.
- `FILE_BASH_SHELL` selects the shell. Defaults to `sh` on Linux and macOS,
  `cmd.exe` on Windows.
- Child processes run with stdin closed and non-interactive environment
  variables set, so commands waiting for input fail fast instead of hanging.
- `--help` / `-h` and `--version` / `-v`.
- Nix flake and package.

### Platforms

Linux, macOS, and Windows. Temporary directory resolution follows each
platform's conventions.

[Unreleased]: https://github.com/Sc3l3t0n/file_bash/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Sc3l3t0n/file_bash/releases/tag/v0.1.0
