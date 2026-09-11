# Agent instructions

With `fb` available on `PATH`, `fb install [target]` adds its minimal
instructions to a global agent instruction file, and `fb uninstall [target]`
removes them again. `init` is an alias for `install`. The target defaults to
`agents`.

| Target          | File                  |
| --------------- | --------------------- |
| `agents`        | `~/.agents/AGENTS.md` |
| `claude`        | `~/.claude/CLAUDE.md` |
| `codex`         | `~/.codex/AGENTS.md`  |
| `antigravity`   | `~/.gemini/GEMINI.md` |
| `custom <path>` | the given file        |

```sh
fb install
fb install codex
fb install custom ~/.config/rules.md
fb uninstall claude
```

Named targets install globally only. Home lookup uses `HOME` on Unix and
`USERPROFILE` on Windows. Missing, empty, or relative home paths are errors.
`custom` takes the path of the instruction file itself; a relative path is
resolved against the current working directory.

Install creates missing directories and files, and adds or updates a section
between `<!-- fb:begin -->` and `<!-- fb:end -->`. Uninstall removes only that
section, preserving surrounding content and leaving the file in place.
Repeated installs and uninstalls are safe. Malformed or duplicate markers
produce an error without modifying the file.
