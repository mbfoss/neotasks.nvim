#!/usr/bin/env python3
"""Build step for the README demo: write a fake artifact under outdir."""

import pathlib
import sys
import time

outdir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build")
outdir.mkdir(parents=True, exist_ok=True)

for step in ("resolve", "compile", "link"):
    print(f"[build] {step}", flush=True)
    time.sleep(0.35)

artifact = outdir / "runner"
artifact.write_text("#!/bin/sh\necho runner\n", encoding="utf-8")
print(f"[build] wrote {artifact}", flush=True)
