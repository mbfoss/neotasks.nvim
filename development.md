# Development

Developer notes for `neotasks.nvim`. For an architectural overview see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Repository layout

```
lua/neotasks/            plugin source
  init.lua                public API (setup, register_* hooks)
  config.lua              runtime config
  commands.lua            :Neotasks user command
  project.lua             project-root discovery
  runner/                 task resolution + execution
  types/                  task-type registry + built-ins + schema merge
  expressions.lua              ${name} value substitutions
  lsp/                    in-process language server for the tasks file
  ui/                     task output (dock.nvim tabs, or a plain split)
  util/                   shared helpers
  tomltools/              VENDORED TOML engine (git subtree, see below)
tests/                    busted specs
```

## Running tests

The suite uses [busted](https://lunarmodules.github.io/busted/), run through
[`tests/nvim-lua`](tests/nvim-lua) so each spec executes inside a real Neovim.

```sh
make test          # alias for unit_test
make unit_test     # busted specs under tests/
```

Run a single spec, or filter, while iterating:

```sh
make test BUSTED_ARGS=tests/completion_spec.lua
make test BUSTED_ARGS="--filter=runner -o gtest"
```

busted must already be installed for Lua 5.1 — the version Neovim embeds —
with `luarocks --lua-version=5.1 --local install busted`; `make test` fails if
it is missing rather than installing anything itself. Specs are
discovered through [`.busted`](.busted), and [`tests/init.lua`](tests/init.lua)
is the busted helper that sets the environment up.

## The help file

`doc/neotasks.txt` is **generated from `README.md`** — never edit it by hand.
[scripts/gendoc.sh](scripts/gendoc.sh) runs the README through
[panvimdoc](https://github.com/kdheepak/panvimdoc) and refreshes `doc/tags`:

```sh
scripts/gendoc.sh                  # rewrite doc/neotasks.txt and doc/tags
scripts/gendoc.sh --check          # exit 1 when the help file is out of date
scripts/gendoc.sh --check --diff   # …and show what changed
```

It needs `pandoc`. panvimdoc is fetched on first run
into `${XDG_CACHE_HOME:-~/.cache}/panvimdoc-<commit>` and pinned to the commit
in `PANVIMDOC_COMMIT` (a tag can be moved, a commit cannot), so the output is
reproducible; the script refuses to reuse a cache that has drifted off that
commit. Set `PANVIMDOC_DIR` to a checkout of your own to use that instead.
`nvim` is only used to refresh `doc/tags` and is optional.

Anything wrapped in `<!-- panvimdoc-ignore-start -->` / `<!-- panvimdoc-ignore-end -->`
in the README is left out of the help file — that is how the markdown table of
contents and the license section are kept out.

### Help tags

By default panvimdoc derives a section's help tag from its heading text, so
`## Shared task options` would become `*neotasks-shared-task-options*`. Add a
trailing `<!-- tag: … -->` comment to pick the tag yourself instead — the
project name is prefixed for you, and the comment is invisible on GitHub:

```markdown
## Shared task options <!-- tag: options -->
```

That yields `*neotasks-options*`, and every `|…|` cross-reference to the
section is rewritten to match. Prefer explicit tags for sections you expect to
link to: the tag then survives a reworded heading. Tags must match
`[A-Za-z0-9_-]+`, and the mechanism keys off the derived tag, so it only works
on plain-text headings — a heading containing backticks or other punctuation
(`### \`process\``) has to keep its derived tag.

## The vendored TOML engine (`tomltools`)

The TOML parser/decoder/encoder/validator/formatter and the schema
navigation used by the LSP all live in the separate
[`tomltools`](https://github.com/mbfoss/tomltools) repository. It is vendored
into this plugin as a **git subtree** (not a submodule), so a fresh clone has
everything it needs with no extra fetch step.

### Why it is namespaced under `neotasks.`

Upstream `tomltools` ships its library at `lua/tomltools/` and its modules
`require` each other by the absolute name `tomltools.*`. If we vendored it at
the runtimepath-visible path `lua/tomltools/`, the top-level module name
`tomltools` would be **global to Neovim**: any other installed plugin that also
vendored `tomltools` would collide, and whichever loaded first would silently
win for both.

To make collisions impossible, the engine is vendored under this plugin's own
namespace instead:

| | |
|---|---|
| Vendored at | `lua/neotasks/tomltools/` |
| Imported as | `require("neotasks.tomltools")` (and `.parser`, `.Cst`, …) |

**Invariant:** every internal `require("tomltools…")` inside the vendored files
is rewritten to `require("neotasks.tomltools…")`. The update script below
re-applies this rewrite on every sync. LuaCATS type annotations
(`---@class tomltools.Cst`, etc.) are left as the upstream `tomltools.*` names —
they are documentation only and do not affect module resolution.

### Updating the vendored engine

Run the update script. It adds the upstream remote if missing, mirrors
`lua/tomltools/*.lua` into `lua/neotasks/tomltools/` with the namespace rewrite
applied, prunes any files upstream deleted, verifies no bare `tomltools` require
survived, and records the pinned commit in [scripts/tomltools.lock](scripts/tomltools.lock):

```sh
scripts/update-tomltools.sh          # vendor upstream main
scripts/update-tomltools.sh v1.2.3   # …or a specific tag / branch / commit
```

The script does **not** commit. Review the diff, run the suite, then commit:

```sh
git diff lua/neotasks/tomltools
make test
git add lua/neotasks/tomltools scripts/tomltools.lock
git commit -m "Update vendored tomltools"
```

The currently vendored commit is recorded in `scripts/tomltools.lock`. Note that
the pinned commit may lag `main` on purpose — pass an explicit ref to move it.

### After updating: check the consuming API

The plugin calls into the engine at a handful of sites; if the `tomltools`
public or submodule API changed, these must be updated to match:

- `runner/exec.lua`, `commands.lua` — `toml.parse`, `toml.find_path`,
  `toml.encode` (whole-document → `string`), `toml.encode_entry` (styled
  snippet → `string[]`).
- `lsp/server/*` — direct use of submodules `parser`, `decoder`, `formatter`,
  `validator`, `Cst`, `schema_nav`, `schema_util`.

A good smoke test is to open a `neotasks.toml` (LSP completion/diagnostics/hover)
and run a task via `:Neotasks`, in addition to `make test`.
