// Asserts every JS file in the repo passes `node --check`.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const EXCLUDE = new Set([".git", ".kilo", "worktrees", "__pycache__", "node_modules"]);

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (EXCLUDE.has(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.name.endsWith(".js")) out.push(p);
  }
  return out;
}

const files = walk(ROOT);
let bad = 0;
for (const f of files) {
  try {
    execFileSync(process.execPath, ["--check", f], { stdio: "pipe" });
  } catch (err) {
    bad += 1;
    console.log(`FAIL ${f}: ${(err.stderr || err.message || "").toString().split("\n")[0]}`);
  }
}
console.log(`js-syntax: ${files.length} files checked, ${bad} with errors`);
process.exit(bad ? 1 : 0);
