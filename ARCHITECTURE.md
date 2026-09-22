# Architecture

A Neovim task runner. Tasks are declared in a per-project TOML file
(`neotasks.toml` by default) and run through `:Neotasks`.

Provides:

- schema-backed LSP completion/diagnostics for the tasks file, via a vendored
  TOML engine under [tomltools/](lua/neotasks/tomltools/) and
  [lsp/](lua/neotasks/lsp/);
- built-in task types, task dependencies, value expressions;
- a status-panel UI.

Public API — [lua/neotasks/init.lua](lua/neotasks/init.lua):

- `setup` (mandatory, callable once)
- extension points `register_task_type`, `register_qfmatcher`,
  `register_expression`

## Modules

- [config.lua](lua/neotasks/config.lua) — runtime config table (tasks filename,
  storage dir), mutated in place by `setup`.
- [project.lua](lua/neotasks/project.lua) — project root, located by finding
  the tasks file in cwd.
- [commands.lua](lua/neotasks/commands.lua) — `:Neotasks` subcommand dispatch
  and completion. The command itself is created by `setup()` in
  [init.lua](lua/neotasks/init.lua), which requires no Lua until first use.
- [runner/](lua/neotasks/runner/) — resolves and executes tasks: `resolver`
  builds the dependency order, `exec` runs them.
- [types/](lua/neotasks/types/) — task-type registry and built-ins
  (`process`/`shell`, `debug`, `composite`).
  - `process` and `shell` are implemented independently, sharing only the
    quickfix-matcher library in
    [types/qfmatchers.lua](lua/neotasks/types/qfmatchers.lua) (built-ins plus
    the user-registered matcher registry).
  - Each type contributes a JSON Schema fragment;
    [types/schema.lua](lua/neotasks/types/schema.lua) merges them with the
    shared `base_properties` (name, `if_running`, `depends_on`,
    `depends_order`) into the schema the LSP uses.
  - `save_buffers` is not shared: a type opts in with
    `supports_save_buffers = true`, which adds the property to its schema and
    has the runner save buffers before `start()` (`process`, `shell`, `debug`
    do). Other types may use the field name freely.
- [expressions.lua](lua/neotasks/expressions.lua) — `{{ name }}` /
  `{{ name args }}` substitutions in task config values.
- [tomltools/](lua/neotasks/tomltools/) — vendored TOML engine (parser,
  decoder, encoder, schema validator/navigator).
  [tomltools/init.lua](lua/neotasks/tomltools/init.lua) exposes the public
  `parse`/`encode`/`find_path` API used by the runner and commands.
- [lsp/](lua/neotasks/lsp/) — vendored in-process language server for the
  tasks file (completion, diagnostics, hover, code actions, formatting),
  driven by the resolved task schema. Declared for the `neotasks` filetype by
  `setup()` and started by Neovim itself; its `root_dir` guard keeps it to the
  real tasks file.
- [ui/](lua/neotasks/ui/) — task output.
  [runview.lua](lua/neotasks/ui/runview.lua) is the only subscriber to the
  runner's signals: it gives every run its own scratch log buffer and shows
  that plus the run's task buffers, either as a
  [dock.nvim](https://github.com/mbfoss/dock.nvim) group (one tab per run) or
  in the plain bottom split of
  [output_win.lua](lua/neotasks/ui/output_win.lua).
- [util/](lua/neotasks/util/) — shared helpers (async, signals, terminal,
  windows, ...).

## Testing

[busted](https://lunarmodules.github.io/busted/) specs in [tests/](tests/),
run through [`tests/nvim-lua`](tests/nvim-lua) so each spec executes inside a
real Neovim.

```sh
make test

# a single spec, or a filter
make test BUSTED_ARGS=tests/completion_spec.lua
make test BUSTED_ARGS="--filter=runner"
```

busted must already be installed for Lua 5.1 — the version Neovim embeds —
with `luarocks --lua-version=5.1 --local install busted`. `make test` fails if
it is missing rather than installing anything.

## Styling

- Lua annotations (`---@param`, `---@return`, `---@class`, ...) wherever
  possible.
- Class-based modules: PascalCase. Functional modules: snake_case.
- Module-scope `local` variables are `_`-prefixed, except a local bound
  directly from `require()`, the conventional `M` module table, and class type
  names like `MyType`.
- Private class members are `_`-prefixed.
- Function-local variable names do NOT begin with an underscore.
