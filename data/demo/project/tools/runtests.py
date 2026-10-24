#!/usr/bin/env python3
"""Test step for the README demo: print a fixed, pytest-like result set."""

import time

RESULTS = [
    ("tests/test_parser.py::test_scalars", True),
    ("tests/test_parser.py::test_tables", True),
    ("tests/test_runner.py::test_depends_on", True),
    ("tests/test_runner.py::test_parallel", False),
]

for name, passed in RESULTS:
    print(("PASS " if passed else "FAIL ") + name, flush=True)
    time.sleep(0.3)

print("tests/test_runner.py:12: AssertionError: expected 3 workers, got 1", flush=True)
print("3 passed, 1 failed", flush=True)
raise SystemExit(1)
