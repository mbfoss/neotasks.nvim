#!/usr/bin/env bash
#
# Update the vendored TOML engine (lua/neotasks/tomltools) from upstream
# https://github.com/mbfoss/tomltools.
#
# Upstream ships its library at lua/tomltools/, and its modules require each
# other by the bare name `tomltools.*`. Vendoring it at that bare path would make
# the top-level module name `tomltools` global to Neovim and collide with any
# other plugin that also vendors it. To make collisions impossible the engine is
# re-namespaced under this plugin:
#
#   * it lives at      lua/neotasks/tomltools/
#   * every internal   require("tomltools…")  is rewritten to
#                      require("neotasks.tomltools…")
#
# LuaCATS annotations (`---@class tomltools.Cst`) are left as upstream's names —
# they are documentation only and do not affect module resolution.
#
# This script mirrors lua/tomltools/*.lua into the vendored prefix with that
# rewrite applied, prunes files that upstream deleted, and records the pinned
# commit in scripts/tomltools.lock. It does NOT commit: review `git diff`, run
# `make test`, and adapt any consumers (see the closing notes) before committing.
#
# Usage:
#   scripts/update-tomltools.sh [REF]
#
#     REF   upstream branch, tag, or commit to vendor. Default: main.
#
set -euo pipefail

# --- Configuration -----------------------------------------------------------
REMOTE_NAME="tomltools"
REMOTE_URL="https://github.com/mbfoss/tomltools.git"
UPSTREAM_SUBDIR="lua/tomltools"          # where the library lives upstream
VENDOR_DIR="lua/neotasks/tomltools"     # where it lives in this plugin
LOCK_FILE="scripts/tomltools.lock"
REF="${1:-main}"

# --- Run from the repo root --------------------------------------------------
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

# --- Ensure the upstream remote exists, then fetch ---------------------------
if ! git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    echo "→ adding remote '$REMOTE_NAME' → $REMOTE_URL"
    git remote add "$REMOTE_NAME" "$REMOTE_URL"
fi
echo "→ fetching '$REMOTE_NAME'"
git fetch --quiet "$REMOTE_NAME"

# Resolve REF: prefer a remote-tracking branch, otherwise take it verbatim
# (so tags and raw SHAs work too).
if git rev-parse --verify --quiet "$REMOTE_NAME/$REF^{commit}" >/dev/null; then
    rev="$REMOTE_NAME/$REF"
else
    rev="$REF"
fi
sha="$(git rev-parse --verify "${rev}^{commit}")"
echo "→ vendoring '$UPSTREAM_SUBDIR' from $rev ($sha)"

# --- Sanity check: the library subdir exists at that ref ---------------------
if [ -z "$(git ls-tree "$sha" -- "$UPSTREAM_SUBDIR")" ]; then
    echo "!! '$UPSTREAM_SUBDIR' does not exist at $rev" >&2
    exit 1
fi

# --- Mirror upstream *.lua into the vendored prefix, applying the rewrite -----
mkdir -p "$VENDOR_DIR"
new_set="$(mktemp)"
trap 'rm -f "$new_set"' EXIT

git ls-tree -r --name-only "$sha" -- "$UPSTREAM_SUBDIR" \
    | grep -E '\.lua$' \
    | while IFS= read -r src; do
        rel="${src#"$UPSTREAM_SUBDIR"/}"      # path relative to the subdir
        dest="$VENDOR_DIR/$rel"
        mkdir -p "$(dirname "$dest")"
        git show "$sha:$src" \
            | perl -pe 's/(require\(\s*["\x27])tomltools/${1}neotasks.tomltools/g' \
            > "$dest"
        printf '%s\n' "$dest" >> "$new_set"
        echo "   • $rel"
    done

# --- Prune vendored *.lua that upstream no longer ships ----------------------
while IFS= read -r -d '' existing; do
    if ! grep -qxF "$existing" "$new_set"; then
        echo "   ✗ pruning (gone upstream): ${existing#"$VENDOR_DIR"/}"
        git rm --quiet "$existing" 2>/dev/null || rm -f "$existing"
    fi
done < <(find "$VENDOR_DIR" -name '*.lua' -print0)

# --- Enforce the invariant: no bare `tomltools` require may survive ----------
if grep -rEn 'require\(\s*["'"'"']tomltools' "$VENDOR_DIR"; then
    echo "!! bare 'tomltools' requires remain (above) — the rewrite missed them" >&2
    exit 1
fi
echo "→ ok: every require is namespaced under neotasks.tomltools"

# --- Record the pinned commit ------------------------------------------------
{
    echo "# Pinned upstream commit for $VENDOR_DIR."
    echo "# Written by scripts/update-tomltools.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo "repo=$REMOTE_URL"
    echo "ref=$REF"
    echo "commit=$sha"
} > "$LOCK_FILE"
echo "→ pinned $LOCK_FILE @ $sha"

# --- Summary -----------------------------------------------------------------
echo
echo "Done. Nothing was committed. Next:"
echo
git status --short "$VENDOR_DIR" "$LOCK_FILE" | sed 's/^/   /' || true
echo
echo "   make test"
echo "   git add $VENDOR_DIR $LOCK_FILE && git commit -m 'Update vendored tomltools'"
echo
echo "If upstream's public/submodule API changed, update the consumers to match:"
echo "   runner/exec.lua, commands.lua  — toml.parse / find_path / encode / encode_entry"
echo "   lsp/server/*                   — parser / decoder / formatter / validator / Cst / schema_*"
