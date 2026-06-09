#!/bin/bash
# verify.sh for Sprint 1: todo-app
# Two layers:
#   1. Static checks (functions exist, structure ok)
#   2. UI test (Playwright, headless chromium)
# Contract: exit 0 = PASS, otherwise FAIL.

set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

echo "=== verify.sh: todo-app ==="

# --- Layer 1: static ---
echo "[static] file structure"
test -f code/index.html || { echo "FAIL: code/index.html missing"; exit 1; }

echo "[static] html basics"
grep -q '<html' code/index.html || { echo "FAIL: not html"; exit 1; }
grep -q '</html>' code/index.html || { echo "FAIL: not closed"; exit 1; }

echo "[static] required functions"
grep -q 'function add' code/index.html || { echo "FAIL: add() missing"; exit 1; }
grep -q 'function toggle' code/index.html || { echo "FAIL: toggle() missing"; exit 1; }
grep -q 'function remove' code/index.html || { echo "FAIL: remove() missing"; exit 1; }
grep -q 'function render' code/index.html || { echo "FAIL: render() missing"; exit 1; }

echo "[static] localStorage used"
grep -q 'setItem' code/index.html || { echo "FAIL: no setItem"; exit 1; }
grep -q 'getItem' code/index.html || { echo "FAIL: no getItem"; exit 1; }

echo "[static] Enter key handler"
grep -q "key === 'Enter'" code/index.html || { echo "FAIL: no Enter handler"; exit 1; }

echo "[static] empty state present"
grep -q 'Нет задач' code/index.html || { echo "FAIL: no empty state"; exit 1; }

# --- Layer 2: UI test ---
echo "[ui] playwright"
if [ ! -d node_modules/playwright ]; then
  echo "FAIL: playwright not installed. Run: npm install"
  exit 1
fi

if ! node scripts/ui-test.js; then
  echo "FAIL: UI test failed"
  exit 1
fi

echo "=== verify.sh: PASS ==="
exit 0
