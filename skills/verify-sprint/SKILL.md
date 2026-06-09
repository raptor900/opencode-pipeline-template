---
name: verify-sprint
description: Написание и запуск verify.sh для спринта. Используй когда нужно: написать verify.sh для нового спринта, расширить существующий, добавить UI-проверки.
---

# verify-sprint

`scripts/verify.sh` — **независимая проверка**, не зависящая от LLM. Это последняя линия обороны против "build сказал готово, а на самом деле нет".

## Контракт verify.sh

- **Exit 0 = PASS, иначе FAIL.** Жёстко.
- Скрипт идемпотентный (можно запускать много раз).
- Без интерактивного ввода.
- Stdout/stderr информативны: первая строка каждой проверки — `echo "check: <name>"`.
- Каждая проверка — атомарная. Падение одной не маскируется под "общий FAIL".

## Структура

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."

echo "=== verify.sh: <sprint> ==="

# --- Layer 1: static ---
echo "[static] file structure"
test -f code/index.html || { echo "FAIL: missing"; exit 1; }

echo "[static] required patterns"
grep -q 'function add' code/index.html || { echo "FAIL: add() missing"; exit 1; }

# --- Layer 2: unit tests (if applicable) ---
echo "[unit] jest/vitest"
npm test --silent || { echo "FAIL: unit tests"; exit 1; }

# --- Layer 3: UI (if applicable) ---
echo "[ui] playwright"
if [ ! -d node_modules/playwright ]; then
  echo "FAIL: playwright not installed. Run: npm install"
  exit 1
fi
node scripts/ui-test.js || { echo "FAIL: UI test"; exit 1; }

echo "=== verify.sh: PASS ==="
exit 0
```

## Слои (по возрастанию строгости)

### Layer 1: static (grep, file exist)
- Плюс: быстро, детерминированно, ловит отсутствие.
- Минус: не ловит "функция есть, но не работает".
- **Минимум, не максимум.**

### Layer 2: unit (jest, vitest, pytest)
- Плюс: логика, не синтаксис.
- Минус: нужно писать тесты в коде проекта.
- **Обязательно для non-trivial логики.**

### Layer 3: UI (playwright, chrome-devtools)
- Плюс: единственное, что ловит визуальные баги.
- Минус: тяжело (chromium ~150MB), flaky.
- **Обязательно для frontend-проектов.**

### Layer 4: integration / E2E
- Плюс: проверяет весь flow.
- Минус: очень хрупко, долго.
- **Только для критичных сценариев.**

## Правила

- Один `echo "check: <name>"` на проверку.
- `set -e` ловит ошибки автоматически.
- Зависимости устанавливаются наверху один раз.
- Долгая проверка — флаг `[slow]` в начале, чтобы можно было скипнуть при итерации.
- Если проверка может флакать — retry с backoff внутри, не "и так сойдёт".

## Playwright-тест: как писать

```js
// scripts/ui-test.js
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const filePath = path.join(ROOT, req.url === '/' ? '/code/index.html' : req.url);
      fs.readFile(filePath, (err, data) => {
        if (err) { res.writeHead(404); res.end(); return; }
        res.writeHead(200); res.end(data);
      });
    });
    server.listen(8765, () => resolve(server));
  });
}

function check(label, cond) {
  console.log(cond ? `  ✓ ${label}` : `  ✗ ${label}`);
  if (!cond) process.exitCode = 1;
}

(async () => {
  const server = await startServer();
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('pageerror', e => { console.log(`  ✗ page error: ${e.message}`); process.exitCode = 1; });
  
  try {
    await page.goto('http://localhost:8765/');
    // ... assertions ...
  } finally {
    await browser.close();
    server.close();
  }
})();
```

## Что проверять в UI-тесте

- **DOM state** — элемент появился/исчез, класс добавлен/убран, текст совпадает.
- **Computed CSS** — `getComputedStyle(el).textDecorationLine.includes('line-through')`.
- **Input state** — `checkbox.checked`, `input.value`.
- **Persistence** — `page.reload()` → state сохранился.
- **Errors** — `pageerror` event, `console.error`.
- **НЕ проверять:** pixel-perfect скриншоты, анимации, third-party виджеты.

## Установка playwright в проекте

```bash
npm init -y
npm install --save-dev playwright
npx playwright install chromium  # один раз
```

`npx playwright install` качает chromium ~150MB. На обеих машинах Юры это надо сделать один раз.
