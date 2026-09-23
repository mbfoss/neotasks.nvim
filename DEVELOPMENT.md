# Development

Developer notes for `neotasks.nvim`. Architectural overview:
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

[busted](https://lunarmodules.github.io/busted/), run through
[`tests/nvim-lua`](tests/nvim-lua) so each spec executes inside a real Neovim.

```sh
make test          # alias for unit_test
make unit_test     # busted specs under tests/
```

A single spec, or a filter:

```sh
make test BUSTED_ARGS=tests/completion_spec.lua
make test BUSTED_ARGS="--filter=runner -o gtest"
```

- busted must already be installed for Lua 5.1 (the version Neovim embeds),
  with `luarocks --lua-version=5.1 --local install busted`; `make test` fails
  if it is missing rather than installing anything.
- Specs are discovered through [`.busted`](.busted).
- [`tests/init.lua`](tests/init.lua) is the busted helper that sets up the
  environment.

## The help file

`doc/neotasks.txt` is **generated from `README.md`**: never edit it by hand.
[scripts/gendoc.sh](scripts/gendoc.sh) runs the README through
[panvimdoc](https://github.com/kdheepak/panvimdoc) and refreshes `doc/tags`:

```sh
scripts/gendoc.sh                  # rewrite doc/neotasks.txt and doc/tags
scripts/gendoc.sh --check          # exit 1 when the help file is out of date
scripts/gendoc.sh --check --diff   # …and show what changed
```

- Needs `pandoc`. `nvim` is used only to refresh `doc/tags` and is optional.
- panvimdoc is fetched on first run into
  `${XDG_CACHE_HOME:-~/.cache}/panvimdoc-<commit>`, pinned to
  `PANVIMDOC_COMMIT` (a tag can be moved, a commit cannot), so output is
  reproducible; the script refuses a cache that has drifted off that commit.
- `PANVIMDOC_DIR` points at a checkout of your own instead.
- Anything between `<!-- panvimdoc-ignore-start -->` and
  `<!-- panvimdoc-ignore-end -->` is left out of the help file: that is how
  the markdown table of contents and the license section are kept out.

### Help tags

panvimdoc derives a section's tag from its heading text, so
`## Shared task options` would become `*neotasks-shared-task-options*`. A
trailing `<!-- tag: … -->` comment picks the tag instead: project name
prefixed automatically, comment invisible on GitHub:

```markdown
## Shared task options <!-- tag: options -->
```

- Yields `*neotasks-options*`, and every `|…|` cross-reference is rewritten to
  match.
- Prefer explicit tags for sections you expect to link to: the tag then
  survives a reworded heading.
- Tags must match `[A-Za-z0-9_-]+`.
- The mechanism keys off the derived tag, so it works only on plain-text
  headings; a heading containing backticks or other punctuation
  (`### \`process\``) keeps its derived tag.

## The vendored TOML engine (`tomltools`)

The TOML parser/decoder/encoder/validator/formatter and the schema navigation
the LSP uses live in the separate
[`tomltools`](https://github.com/mbfoss/tomltools) repository, vendored here as
a **git subtree** (not a submodule), so a fresh clone needs no extra fetch.

### Why it is namespaced under `neotasks.`

- Upstream ships its library at `lua/tomltools/`, its modules requiring each
  other by the absolute name `tomltools.*`.
- Vendored at the runtimepath-visible `lua/tomltools/`, the top-level module
  name `tomltools` would be **global to Neovim**: any other plugin vendoring
  `tomltools` would collide, and whichever loaded first would silently win for
  both.
- So it is vendored under this plugin's own namespace:

| | |
|---|---|
| Vendored at | `lua/neotasks/tomltools/` |
| Imported as | `require("neotasks.tomltools")` (and `.parser`, `.Cst`, …) |

**Invariant:** every internal `require("tomltools…")` inside the vendored files
is rewritten to `require("neotasks.tomltools…")`; the update script re-applies
this on every sync. LuaCATS annotations (`---@class tomltools.Cst`, etc.) keep
the upstream names, for documentation only, with no effect on module
resolution.

### Updating the vendored engine

```sh
scripts/update-tomltools.sh          # vendor upstream main
scripts/update-tomltools.sh v1.2.3   # …or a specific tag / branch / commit
```

The script adds the upstream remote if missing, mirrors `lua/tomltools/*.lua`
into `lua/neotasks/tomltools/` with the namespace rewrite, prunes files
upstream deleted, verifies no bare `tomltools` require survived, and records
the pinned commit in [scripts/tomltools.lock](scripts/tomltools.lock).

It does **not** commit:

```sh
git diff lua/neotasks/tomltools
make test
git add lua/neotasks/tomltools scripts/tomltools.lock
git commit -m "Update vendored tomltools"
```

The pinned commit may lag `main` on purpose; pass an explicit ref to move it.

### After updating: check the consuming API

If the `tomltools` public or submodule API changed, these call sites must
follow:

- `runner/exec.lua`, `commands.lua`: `toml.parse`, `toml.find_path`,
  `toml.encode` (whole-document → `string`), `toml.encode_entry` (styled
  snippet → `string[]`).
- `lsp/server/*`: direct use of submodules `parser`, `decoder`, `formatter`,
  `validator`, `Cst`, `schema_nav`, `schema_util`.

Smoke test, besides `make test`: open a `neotasks.toml` (LSP
completion/diagnostics/hover) and run a task via `:Neotasks`.
