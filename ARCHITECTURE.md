# Architecture

`neotasks.nvim` is a Neovim task runner. Tasks are declared in a per-project
TOML file (`neotasks.toml` by default) and run from within Neovim via the `:Neotasks`
command. The plugin provides schema-backed LSP completion/diagnostics for the
tasks file (via a vendored TOML engine + language server under
[tomltools/](lua/neotasks/tomltools/) and [lsp/](lua/neotasks/lsp/)), several built-in
task types, task dependencies, value expressions, and a status-panel UI.

The public API lives in [lua/neotasks/init.lua](lua/neotasks/init.lua):
`setup` (mandatory, callable once), and the extension points `register_task_type`,
`register_qfmatcher`, and `register_expression`.

## Modules

- [config.lua](lua/neotasks/config.lua) — runtime config table (command name,
  tasks filename, storage dir). Mutated in place by `setup`.
- [project.lua](lua/neotasks/project.lua) — locates the project root by finding
  the tasks file in cwd.
- [commands.lua](lua/neotasks/commands.lua) — `:Neotasks` subcommand dispatch and
  completion. The command itself is created by `setup()` in
  [init.lua](lua/neotasks/init.lua), which requires no Lua until the command
  is first used.
- [runner/](lua/neotasks/runner/) — resolves and executes tasks
  (`resolver` builds the dependency order, `exec` runs them).
- [types/](lua/neotasks/types/) — task-type registry and built-in types
  (`process`/`shell`, `debug`, `composite`). `process` and `shell` are
  implemented independently; they only share the quickfix-matcher library in
  [types/qfmatchers.lua](lua/neotasks/types/qfmatchers.lua) (built-in matchers
  plus the user-registered matcher registry). Each type contributes a JSON Schema
  fragment; [types/schema.lua](lua/neotasks/types/schema.lua) merges them with
  the shared `base_properties` (name, `if_running`, `depends_on`,
  `depends_order`) into the full schema used by the LSP.
- [expressions.lua](lua/neotasks/expressions.lua) — `{{ name }}` / `{{ name args }}`
  substitutions available in task config values.
- [tomltools/](lua/neotasks/tomltools/) — vendored TOML engine (parser, decoder,
  encoder, schema validator/navigator). [tomltools/init.lua](lua/neotasks/tomltools/init.lua)
  exposes the public `parse`/`encode`/`find_path` API used by the runner and
  commands.
- [lsp/](lua/neotasks/lsp/) — vendored in-process language server for the tasks
  file (completion, diagnostics, hover, code actions, formatting), driven by the
  resolved task schema. Declared for the `neotasks` filetype by `setup()` and started by Neovim itself;
  its `root_dir` guard keeps it to the real tasks file.
- [ui/](lua/neotasks/ui/) — task output. [runview.lua](lua/neotasks/ui/runview.lua)
  is the only subscriber to the runner's signals: it gives every run its own
  scratch log buffer and shows that plus the run's task buffers either as a
  [dock.nvim](https://github.com/mbfoss/dock.nvim) group (one tab per run, when
  dock is installed) or in the plain bottom split of
  [output_win.lua](lua/neotasks/ui/output_win.lua).
- [util/](lua/neotasks/util/) — shared helpers (async, signals, terminal,
  windows, etc.).


## Testing

Tests use [busted](https://lunarmodules.github.io/busted/) and live in
[tests/](tests/), running through [`tests/nvim-lua`](tests/nvim-lua) so each
spec executes inside a real Neovim. Run them with:

```sh
make test

# a single spec, or a filter
make test BUSTED_ARGS=tests/completion_spec.lua
make test BUSTED_ARGS="--filter=runner"
```

busted must already be installed for Lua 5.1 — the version Neovim embeds —
with `luarocks --lua-version=5.1 --local install busted`; `make test` fails if
it is missing rather than installing anything itself.

## Styling

Add Lua annotations (`---@param`, `---@return`, `---@class`, etc.) whenever possible.

Class-based modules are named in PascalCase; functional modules are named in snake_case.

Module-scope `local` variables are prefixed with `_`, except:
- a local name bound directly from `require()`
- the conventional `M` module table
- class type names like `MyType`

Inside a class, private members are prefixed with `_`.

Function local variable names should NOT begin with underscore
