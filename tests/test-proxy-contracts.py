"""Proxy contract: server/torbox-proxy.py must expose the routes/env the stack depends on."""
import ast
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROXY = ROOT / "server" / "torbox-proxy.py"

REQUIRED_LITERALS = [
    "/mylist",
    "/metrics",
    "/ready",
    "/health",
    "/torbox/",
    "requestdl",
    "TORBOX_API_KEY",
]

if not PROXY.exists():
    print("SKIP: no server/torbox-proxy.py")
    sys.exit(0)

src = PROXY.read_text(encoding="utf-8")
try:
    ast.parse(src)
except SyntaxError as ex:
    print(f"FAIL syntax: {ex}")
    sys.exit(1)

missing = [lit for lit in REQUIRED_LITERALS if lit not in src]
if missing:
    print(f"FAIL missing contracts: {', '.join(missing)}")
    sys.exit(1)
print(f"proxy-contracts: all {len(REQUIRED_LITERALS)} route/env contracts present")
sys.exit(0)
