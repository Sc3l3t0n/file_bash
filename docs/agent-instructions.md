# Agent instructions

With `fb` available on `PATH`, install its minimal instructions into a global
agent instruction file:

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
section, preserving surrounding content and leaving the file in place.
Repeated installs and uninstalls are safe. Malformed or duplicate markers
produce an error without modifying the file.
