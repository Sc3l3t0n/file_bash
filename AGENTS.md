# Repository guidelines

- Keep implementations small and allocation-conscious. Borrow argument slices,
  use the existing arena when allocation is needed, and pass only the values a
  function requires. Add buffers, helpers, or abstractions only when they simplify
  the implementation.
- Keep modules focused on one responsibility; follow the existing separation of
  command parsing, shell selection, directory handling, and instruction updates.
- Prefer comptime constants and enum-owned static string maps for named choices
  and aliases. Use enum conversion when names map directly to tags.
- Use `@tagName`, inline switch branches, and standard-library helpers where they
  simplify the code. Fully initialize argument arrays before exposing them.
- Use Zig `\\` multiline strings, trailing commas in multiline declarations,
  and blank lines between logical groups. Format Zig changes with `zig fmt`.
- Make CLI and platform decisions explicit. Support Linux, macOS, and Windows
  directly, using documented environment conventions and explicit errors when
  configuration is invalid rather than guessing alternative values.
- Prepare buffered stdout/stderr writers in `main`; send user-facing errors to
  stderr and use `fb` consistently in CLI messages.
- Keep generated agent instructions brief and actionable. Changes to user-owned
  instruction files must preserve surrounding content, be reversible and
  idempotent, and reject ambiguous section markers before writing.
- call allocators arena or gpa instead of allocator or alloc
- Declare `@import` bindings at file scope; use the named bindings in declarations
  and functions instead of inline imports.
- use `const t = std.testing` in tests
