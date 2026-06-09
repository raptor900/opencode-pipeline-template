// UI test for todo-app using Playwright.
// Verifies all UI criteria from contracts/sprint-1.md against a real browser.
// Usage: node scripts/ui-test.js
// Exit 0 = PASS, non-zero = FAIL.

const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PORT = 8765;

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let urlPath = req.url === '/' ? '/code/index.html' : req.url;
      const filePath = path.join(ROOT, urlPath);
      if (!filePath.startsWith(ROOT)) {
        res.writeHead(403); res.end(); return;
      }
      fs.readFile(filePath, (err, data) => {
        if (err) { res.writeHead(404); res.end(); return; }
        const ext = path.extname(filePath);
        const ct = ext === '.html' ? 'text/html' : 'text/plain';
        res.writeHead(200, { 'Content-Type': ct });
        res.end(data);
      });
    });
    server.listen(PORT, () => resolve(server));
  });
}

function check(label, cond, detail = '') {
  if (cond) {
    console.log(`  ✓ ${label}`);
  } else {
    console.log(`  ✗ ${label}${detail ? ' — ' + detail : ''}`);
    process.exitCode = 1;
  }
}

(async () => {
  const server = await startServer();
  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();

  // Surface page errors
  page.on('pageerror', (e) => {
    console.log(`  ✗ page error: ${e.message}`);
    process.exitCode = 1;
  });
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      console.log(`  ✗ console error: ${msg.text()}`);
      process.exitCode = 1;
    }
  });

  try {
    console.log('UI test: todo-app');

    // 1. Empty state visible
    await page.goto(`http://localhost:${PORT}/`);
    await page.waitForSelector('#empty');
    let emptyVisible = await page.isVisible('#empty');
    let itemCount = await page.locator('li').count();
    check('empty state visible on first load', emptyVisible && itemCount === 0);

    // 2. Add todo via Enter
    await page.fill('#new-todo', 'Купить хлеб');
    await page.press('#new-todo', 'Enter');
    await page.waitForSelector('li');
    let text = await page.locator('li span').first().textContent();
    check('todo added via Enter', text === 'Купить хлеб', `got: ${text}`);

    // 3. Toggle complete — visual state
    await page.click('li input[type=checkbox]');
    await page.waitForTimeout(100);  // allow any async work
    let li = page.locator('li').first();
    let hasDoneClass = await li.evaluate(el => el.classList.contains('done'));
    let isChecked = await li.locator('input[type=checkbox]').isChecked();
    // also check that CSS line-through is actually applied to the span
    let textDecoration = await li.locator('span').first().evaluate(el =>
      window.getComputedStyle(el).textDecorationLine
    );
    check(
      'toggle: li has .done class',
      hasDoneClass,
      'classList did not include "done" — render() not called?'
    );
    check(
      'toggle: checkbox reflects done state',
      isChecked,
      'checkbox still unchecked after click'
    );
    check(
      'toggle: visual line-through applied',
      textDecoration.includes('line-through'),
      `computed text-decoration: ${textDecoration}`
    );

    // 4. Reload — state persists
    await page.reload();
    await page.waitForSelector('li');
    let persistedDone = await page.locator('li').first().evaluate(el =>
      el.classList.contains('done')
    );
    check('state persists across reload', persistedDone);

    // 5. Delete todo
    await page.click('li .delete');
    await page.waitForTimeout(100);
    itemCount = await page.locator('li').count();
    emptyVisible = await page.isVisible('#empty');
    check(
      'delete: item removed, empty state shown',
      itemCount === 0 && emptyVisible
    );

    // 6. Add multiple, toggle one
    await page.fill('#new-todo', 'Задача 1');
    await page.press('#new-todo', 'Enter');
    await page.fill('#new-todo', 'Задача 2');
    await page.press('#new-todo', 'Enter');
    itemCount = await page.locator('li').count();
    check('multiple todos', itemCount === 2);
    // toggle the first
    await page.locator('li input[type=checkbox]').first().click();
    await page.waitForTimeout(100);
    let firstDone = await page.locator('li').first().evaluate(el =>
      el.classList.contains('done')
    );
    let secondDone = await page.locator('li').nth(1).evaluate(el =>
      el.classList.contains('done')
    );
    check(
      'toggle only affects clicked item',
      firstDone && !secondDone
    );

  } finally {
    await browser.close();
    server.close();
  }

  if (process.exitCode) {
    console.log('UI test: FAIL');
  } else {
    console.log('UI test: PASS');
  }
})().catch((e) => {
  console.error('UI test crashed:', e);
  process.exit(1);
});
