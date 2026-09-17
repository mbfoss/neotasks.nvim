#!/usr/bin/env sh
# Record the README demos from demo/*.scene with nvim-demo.
#
#   scripts/record-demos.sh                       # every scene
#   scripts/record-demos.sh demo/01-run-task.scene  # just one
#
# Each scene writes its GIF and cast to demo/out/. Needs nvim, agg and pyte.
#
# nvim-demo (https://github.com/mbfoss/nvim-demo-generator) is cloned into
# $XDG_CACHE_HOME/neotasks.nvim when missing; set NVIM_DEMO to a checkout's
# bin/nvim-demo to use that instead.
#
# The scenes route `vim.ui.select` through locator.nvim, which is optional for
# users but needed to record the picker. It is cloned into the same cache
# directory; set LOCATOR_NVIM to a checkout to use that instead.
#
# The GIFs are published on the `assets` branch, not committed here.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/neotasks.nvim

if [ -n "${NVIM_DEMO:-}" ]; then
    demo=$NVIM_DEMO
else
    tool=$cache/nvim-demo-generator
    demo=$tool/bin/nvim-demo
    if [ ! -x "$demo" ]; then
        mkdir -p "$cache"
        git clone --depth 1 \
            https://github.com/mbfoss/nvim-demo-generator "$tool"
    fi
fi

if [ -n "${LOCATOR_NVIM:-}" ]; then
    locator=$LOCATOR_NVIM
else
    locator=$cache/locator.nvim
    if [ ! -d "$locator/lua/locator" ]; then
        mkdir -p "$cache"
        git clone --depth 1 \
            https://github.com/mbfoss/locator.nvim "$locator"
    fi
fi
export LOCATOR_NVIM=$locator

if [ "$#" -eq 0 ]; then
    set -- "$root"/demo/*.scene
fi

mkdir -p "$root/demo/out"

for scene in "$@"; do
    printf '=== %s\n' "$(basename "$scene")"
    "$demo" record "$scene"
done
