"""Asserts every Python file in the repo compiles cleanly."""
import py_compile
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXCLUDE = {".git", ".kilo", "worktrees", "__pycache__", "node_modules"}

files = [
    p for p in ROOT.rglob("*.py")
    if not any(part in EXCLUDE for part in p.parts)
]
bad = 0
for f in sorted(files):
    try:
        py_compile.compile(str(f), doraise=True)
    except Exception as ex:  # noqa: BLE001 - report then fail
        bad += 1
        print(f"FAIL {f}: {ex}")
print(f"py-compile: {len(files)} files checked, {bad} with errors")
sys.exit(1 if bad else 0)
