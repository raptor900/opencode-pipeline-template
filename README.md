# pipeline-template

Шаблон автономного цикла разработки: **planner + build + critic** агенты работают по контрактам, **внешний `driver.sh`** крутит фазы `plan → build → critic → next sprint` без LLM в петле, **`verify.sh`** — независимая bash-проверка (статика + юниты + Playwright для UI).

Вдохновлено [выступлением Anthropic](https://youtu.be/mR-WAvEPRwE) о многочасовой автономной работе агентов.

---

## Содержание

- [TL;DR](#tldr)
- [Quick start](#quick-start)
- [Архитектура](#архитектура)
  - [Цикл фаз](#цикл-фаз)
  - [State machine](#state-machine)
  - [Контракт-первый подход](#контракт-первый-подход)
- [Файловая структура](#файловая-структура)
- [Установка](#установка)
  - [Требования](#требования)
  - [Развёртывание нового проекта](#развёртывание-нового-проекта)
  - [Переносимость между машинами](#переносимость-между-машинами)
- [Полный workflow](#полный-workflow)
  - [Шаг 1: `goal.md`](#шаг-1-goalmd)
  - [Шаг 2: `driver.sh init`](#шаг-2-driversh-init)
  - [Шаг 3: `driver.sh loop`](#шаг-3-driversh-loop)
  - [Шаг 4: наблюдение и вмешательство](#шаг-4-наблюдение-и-вмешательство)
- [Агенты](#агенты)
  - [planner](#planner)
  - [build](#build)
  - [critic](#critic)
- [Контракты](#контракты)
  - [Что считать готовым](#что-считать-готовым)
  - [Шаблон `contracts/sprint-N.md`](#шаблон-contractssprint-nmd)
  - [Согласование](#согласование)
- [`verify.sh`](#verifysh)
  - [Контракт скрипта](#контракт-скрипта)
  - [Слои проверки](#слои-проверки)
  - [Playwright для UI](#playwright-для-ui)
- [`driver.sh`](#driversh)
  - [Команды](#команды)
  - [State.json v2](#statejson-v2)
  - [Переменные окружения](#переменные-окружения)
  - [Cron и systemd](#cron-и-systemd)
  - [Поведение TTY vs non-TTY](#поведение-tty-vs-non-tty)
  - [Точки паузы](#точки-паузы)
  - [DRY_RUN](#dry_run)
- [Skills](#skills)
- [Примеры](#примеры)
- [Принципы](#принципы)
- [Roadmap](#roadmap)
- [Lessons learned](#lessons-learned)
- [Антипаттерны](#антипаттерны)
- [Лицензия](#лицензия)

---

## TL;DR

```bash
cp -r pipeline-template/ my-project && cd my-project
echo "# Goal: мой проект ..." > goal.md
./scripts/driver.sh init
./scripts/driver.sh loop
```

Driver запускает `planner` (LLM читает `goal.md` → пишет `plans/current.md`), затем по каждому спринту — `build` (пишет код и `scripts/verify.sh`) → bash-проверка → `critic` (парсит `VERDICT: PASS/FAIL`). На PASS — следующий спринт. На FAIL — retry, до `max_attempts`. State в `state.json`, в git. На любом этапе можно прервать и продолжить.

Пользователь не запускает opencode напрямую — только `driver.sh` и правит файлы (`goal.md`, `questions.md`, иногда контракт/код).

---

## Quick start

```bash
# 1. Скопировать шаблон
cp -r pipeline-template/ my-project && cd my-project

# 2. Написать goal.md (без кода, на человеческом языке)
cat > goal.md << 'EOF'
# Goal: телеграм-бот для заметок

## Что делаем
Бот: /add <текст> → сохраняет в sqlite, /list → показывает.

## Готово, когда
- Команды /add и /list работают
- Данные переживают рестарт бота
- bash scripts/verify.sh exit 0
EOF

# 3. Запустить цикл
./scripts/driver.sh init
./scripts/driver.sh loop
```

`loop` крутит фазы до `done` или `blocked`. Прервать в любой момент (Ctrl-C) — продолжить с того же места через `driver.sh next`.

---

## Архитектура

### Цикл фаз

```
┌──────┐    ┌───────┐    ┌────────┐    ┌───────┐
│ plan │───▶│ build │───▶│ verify │───▶│ critic│──┐
└──────┘    └───────┘    └────────┘    └───────┘  │
   │             │            │              │    │
   │        retry attempts   exit!=0      FAIL    │
   │             │            │              │    │
   │             ▼            ▼              ▼    │
   │          (build)      (build)        (build) │
   │                                            │
   │                                  PASS       │
   │                                            ▼
   │                              ┌────────────────┐
   │                              │  next sprint   │
   │                              │  или done      │
   │                              └────────────────┘
   │
   └── questions.md → pause → человек → continue
```

- **plan** — `planner` пишет `plans/current.md` (может задать вопросы через `questions.md`)
- **build** — `build` пишет контракт, код, `scripts/verify.sh`, отчёт
- **verify** — driver гоняет `bash scripts/verify.sh`. exit 0 → critic, иначе retry
- **critic** — `critic` пишет `critique/sprint-N.md` с `VERDICT: PASS/FAIL`
- **retry** — при FAIL до `max_attempts` (default 3)
- **next sprint** — на PASS, если есть `contracts/sprint-N+1.md` или упоминание в плане
- **done** — все спринты прошли
- **blocked** — `max_attempts` исчерпан, нужно вмешательство

### State machine

Состояние цикла хранится в `state.json` (создаётся `driver.sh init`):

```json
{
  "schema_version": 2,
  "project": "",
  "sprint": 1,
  "phase": "plan",
  "attempts": 0,
  "max_attempts": 3,
  "plan_path": "plans/current.md",
  "contract_path": "contracts/sprint-1.md",
  "report_path": "reports/sprint-1.md",
  "critique_path": "critique/sprint-1.md",
  "last_verdict": null,
  "last_error": null,
  "last_update": "2026-06-09T08:00:00Z",
  "history": [
    {"ts": "...", "event": "plan", "result": "ok", "sprint": 1, "phase": "plan"}
  ]
}
```

Ключевые свойства:
- `state.json` в git → полная история цикла в репозитории
- `history[]` — append-only лог всех событий (помогает дебажить)
- Перезапуск driver в любой момент продолжает с текущей фазы
- Прерывание cron'ом безопасно: state всегда консистентен

### Контракт-первый подход

Главное правило: **код пишется только после согласованного контракта**.

Контракт — это `contracts/sprint-N.md` со списком auto-checkable критериев. Он:
- Пишется до реализации (на основе `plans/current.md`)
- Согласуется с человеком (через `questions.md` если нужно)
- Не меняется в процессе спринта
- Является единственным источником истины для `critic`

Если критерий нельзя проверить автоматически — `critic` помечает `MANUAL` и предлагает переформулировку в секции "Contract issues".

---

## Файловая структура

```
.
├── opencode.json           # конфиг агентов + permissions
├── agents/
│   ├── planner.md          # промпт planner-агента
│   ├── build.md            # промпт build-агента
│   └── critic.md           # промпт critic-агента
├── templates/
│   ├── plan.md             # шаблон продуктового плана
│   ├── contract.md         # шаблон контракта с auto-checkable критериями
│   └── state.json          # шаблон state для driver'а
├── skills/
│   ├── verify-sprint/      # как писать verify.sh и UI-тесты
│   └── driver-cycle/       # как пользоваться driver.sh
├── scripts/
│   ├── driver.sh           # внешний state-machine
│   └── verify.sh           # независимая проверка
├── state.json              # создаётся driver.sh init, коммитится в git
└── examples/
    └── todo-app/           # полный пример: goal.md + plan + contract + code + tests
```

`state.json` и `plans/current.md` появляются после `driver.sh init` и первого запуска `planner`. `contracts/`, `reports/`, `critique/` — по мере работы цикла.

---

## Установка

### Требования

| Компонент | Версия | Зачем |
|-----------|--------|-------|
| [opencode](https://opencode.ai) | последняя | запуск агентов |
| Node.js | >= 18 | Playwright UI-тесты |
| bash | >= 4 | driver.sh |
| jq | любая | парсинг state.json |
| `anthropic/claude-sonnet-4-5` или аналог | — | модель для агентов |

Playwright нужен только для UI-проектов. Для CLI/бэкенда достаточно bash + стандартных утилит.

### Развёртывание нового проекта

```bash
# 1. Скопировать шаблон
git clone https://github.com/<your-org>/opencode-pipeline-template my-project
cd my-project

# 2. Удалить историю шаблона (опционально)
rm -rf .git && git init

# 3. Написать goal.md
vim goal.md

# 4. Установить playwright (для UI-проектов)
npm init -y
npm install --save-dev playwright
npx playwright install chromium

# 5. Запустить цикл
./scripts/driver.sh init
./scripts/driver.sh loop
```

### Переносимость между машинами

`node_modules/` и `state.json` (опционально для shared worktrees) в `.gitignore`. Бинарь chromium в `~/.cache/ms-playwright/`. На новой машине:

```bash
git clone <repo-url> && cd my-project
npm install                    # восстановит playwright
npx playwright install chromium
./scripts/driver.sh status     # проверить state
./scripts/driver.sh next       # продолжить
```

---

## Полный workflow

### Шаг 1: `goal.md`

Единственный документ, который пользователь пишет на старте. Без кода, без технических деталей.

```markdown
# Goal: телеграм-бот для заметок

## Что делаем
Telegram-бот: /add <текст> → сохраняет в sqlite, /list → показывает последние 10.

## Для кого
Личное использование, single-user, без авторизации.

## Готово, когда
- /add и /list работают
- Данные переживают рестарт бота
- bash scripts/verify.sh exit 0

## Не входит
- Multi-user
- Web UI
- Деплой
```

`planner` прочитает это и разобьёт на спринты в `plans/current.md`. Если ввода не хватает — запишет вопросы в `questions.md` и попросит дополнить.

### Шаг 2: `driver.sh init`

```bash
./scripts/driver.sh init
# → создаёт state.json из templates/state.json
# → phase="plan", sprint=1
```

### Шаг 3: `driver.sh loop`

```bash
./scripts/driver.sh loop
```

Крутит фазы пока `phase != done` и `phase != blocked`. Каждый шаг логируется, history пишется в `state.json`.

Внутренняя последовательность:

```
1. Читает state.json
2. Если phase=plan:
   ├── запускает opencode run --agent planner --message "..."
   ├── planner читает goal.md
   ├── если есть questions.md — пауза (TTY) или auto-skip (cron)
   ├── planner пишет plans/current.md
   └── state.json: phase=build, sprint=1
3. Если phase=build:
   ├── запускает opencode run --agent build --message "..."
   ├── build читает plans/current.md и (если нет) contracts/sprint-N.md
   ├── build пишет код и scripts/verify.sh
   ├── build пишет reports/sprint-N.md
   ├── driver гоняет bash scripts/verify.sh
   │   ├── exit 0 → state.json: phase=critic
   │   └── exit != 0 → attempts++, retry
4. Если phase=critic:
   ├── запускает opencode run --agent critic --message "..."
   ├── critic читает contracts/sprint-N.md, reports/sprint-N.md
   ├── critic гоняет verify.sh
   ├── critic пишет critique/sprint-N.md с VERDICT: PASS/FAIL
   ├── парсинг:
   │   ├── PASS → sprint++, phase=build (или done если спринтов больше нет)
   │   └── FAIL → attempts++, retry (или blocked)
5. Если phase=done или blocked — выход
```

### Шаг 4: наблюдение и вмешательство

Терминал показывает прогресс:

```
▸ [plan] spawning planner
✓ [plan] plans/current.md created

▸ [build] sprint=1 contract=contracts/sprint-1.md
[08:20] running agent: build
[08:35] ✓ agent build completed
▸ [build] running verify.sh
✓ [build] verify.sh passed

▸ [critic] sprint=1
[08:36] ✓ [critic] VERDICT: PASS

▸ [build] sprint=2 contract=contracts/sprint-2.md
...
```

Опциональные точки вмешательства:

1. **`questions.md` появился** — `planner` не хватает ввода. Driver паузится, пользователь дописывает ответы, жмёт Enter.
2. **`critic` FAIL** — посмотреть `critique/sprint-N.md`, решить: править руками / изменить контракт / пусть `build` попробует ещё раз.
3. **blocked (max_attempts)** — сбросить attempts и продолжить: `driver.sh set .attempts 0 && driver.sh set .phase build && driver.sh next`.

Что пользователь **не** делает вручную:
- Не запускает opencode (driver делает это batch-режимом)
- Не пишет `contracts/sprint-N.md` с нуля (`build` создаёт на основе `plans/current.md`)
- Не парсит `VERDICT` руками (driver делает `grep '^VERDICT:'`)
- Не запускает `verify.sh` (driver гоняет после каждого `build`)

---

## Агенты

Конфигурация в `opencode.json`. Промпты — в `agents/*.md`.

### planner

**Назначение:** продуктовое планирование. Из `goal.md` делает `plans/current.md` со списком спринтов, зависимостями, backlog.

**Permissions:** bash, edit, write, read, webfetch (тот же набор что у `build`).

**Контракт поведения:**
- Читает `goal.md`, существующие `plans/current.md`, `state.json`
- Если ввода не хватает — пишет `questions.md` со списком открытых вопросов и выходит
- Если ввода хватает — пишет `plans/current.md` (3-7 спринтов) и выходит
- **Не пишет код и не меняет `goal.md`**

**Output:** `plans/current.md` (обязательно) + опционально `questions.md`.

### build

**Назначение:** реализация одного спринта по контракту.

**Permissions:** bash, edit, write, read, webfetch.

**Контракт поведения:**
- Читает `plans/current.md` и `contracts/sprint-N.md`
- Если контракта нет — пишет сам (используя `templates/contract.md`)
- Пишет код, `scripts/verify.sh`, запускает его локально
- Пишет `reports/sprint-N.md` с описанием работы
- **Не меняет `contracts/sprint-N.md`** (если критерий нереалистичен — в `plans/backlog.md` и остановка)
- **Не выходит за scope спринта** (смежная работа — в `plans/backlog.md`)

**Output:** код + `scripts/verify.sh` (exit 0) + `reports/sprint-N.md`.

### critic

**Назначение:** жёсткая верификация спринта по контракту. **Не может править код** (нет edit/write в permissions).

**Permissions:** read, bash, webfetch, glob, grep.

**Контракт поведения:**
- Читает `contracts/sprint-N.md` (единственный источник истины)
- Читает `reports/sprint-N.md` (что build сделал)
- Прогоняет `bash scripts/verify.sh` сам
- Для каждого критерия даёт **PASS / FAIL / MANUAL** с доказательством
- Если критерии плохо сформулированы — отдельная секция "Contract issues"
- **Последняя строка:** `VERDICT: PASS` или `VERDICT: FAIL`

**Output:** `critique/sprint-N.md` с VERDICT на последней строке.

---

## Контракты

### Что считать готовым

Критерий считается качественным, если у него есть **явный способ верификации**:

| Формулировка | Качество |
|---|---|
| "Кнопка работает" | ❌ Плохо — что значит "работает"? |
| "Клик добавляет элемент в DOM" | ⚠️ Лучше, но нет способа проверки |
| "После клика `#list` содержит `<li>` с текстом X" | ✅ Можно проверить через Playwright |
| "`checkbox.checked === true` после клика" | ✅ Можно проверить |
| "computed `text-decoration-line` содержит `'line-through'`" | ✅ Можно проверить |
| "`npm test` exits 0" | ✅ Можно проверить |
| "Состояние переживает reload" | ⚠️ Нужен сценарий: добавить → reload → проверить |
| "Удобный интерфейс" | ❌ Субъективно, не верифицируемо |

**Если в контракте ≥2 критериев auto-unverifiable → `critic` вернёт "Contract issues", и контракт надо пересогласовать.**

### Шаблон `contracts/sprint-N.md`

См. `templates/contract.md`. Структура:

```markdown
# Sprint N: <название>

## Цель
<одно предложение>

## Критерии готовности

| # | Критерий | Тип | Как верифицировать |
|---|----------|-----|---------------------|
| 1 | <criterion> | static / unit / UI / shell | <команда или сценарий> |

## Out of scope
-

## Зависимости
-

## Согласовано
- Build: ready
- Critic: pending
- Дата: <ISO-8601>
```

### Согласование

1. `planner` пишет `plans/current.md` (продуктовый план)
2. `build` (на старте спринта) пишет `contracts/sprint-N.md` (технические критерии)
3. Пользователь читает контракт, при необходимости правит
4. `build` реализует, `critic` проверяет
5. Контракт **не меняется** до конца спринта

Если критерий нереалистичен — `build` пишет в `plans/backlog.md` как "требует пересогласования" и **останавливается**. Не молча подменяет.

---

## `verify.sh`

`scripts/verify.sh` — **независимая bash-проверка**, не зависящая от LLM. Это последняя линия обороны против "build сказал готово, а на самом деле нет".

### Контракт скрипта

- **Exit 0 = PASS, иначе FAIL.** Жёстко.
- Идемпотентный (можно запускать много раз).
- Без интерактивного ввода.
- Stdout/stderr информативны: первая строка каждой проверки — `echo "check: <name>"`.
- Каждая проверка атомарная. Падение одной не маскируется под "общий FAIL".

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."

echo "=== verify.sh: <sprint> ==="

# --- static ---
echo "check: file structure"
test -f code/index.html || { echo "FAIL: missing"; exit 1; }

# --- unit (если есть) ---
echo "check: unit tests"
npm test --silent || { echo "FAIL: unit tests"; exit 1; }

# --- UI (если есть) ---
echo "check: UI playwright"
node scripts/ui-test.js || { echo "FAIL: UI"; exit 1; }

echo "=== verify.sh: PASS ==="
exit 0
```

### Слои проверки

| Слой | Плюсы | Минусы | Когда |
|------|-------|--------|-------|
| **static** (grep, file exist) | быстро, детерминированно, ловит отсутствие | не ловит "функция есть, но не работает" | всегда, минимум |
| **unit** (jest, vitest, pytest) | логика, не синтаксис | нужно писать тесты | non-trivial логика |
| **UI** (playwright, chrome-devtools) | единственное, что ловит визуальные баги | тяжело (chromium ~150MB), flaky | **обязательно** для frontend |
| **E2E** | весь flow | очень хрупко, долго | только критичные сценарии |

### Playwright для UI

См. `skills/verify-sprint/SKILL.md` — там полный шаблон `scripts/ui-test.js`. Ключевые правила:

- Поднимать локальный HTTP-сервер внутри теста (не надейтесь на внешний)
- Проверять **DOM state** (элемент/класс/текст), **computed CSS** (`getComputedStyle`), **input state** (`checkbox.checked`)
- Ловить `pageerror` и `console.error` как FAIL
- **Не проверять** pixel-perfect скриншоты и анимации

```bash
# Установка в проекте
npm init -y
npm install --save-dev playwright
npx playwright install chromium  # один раз
```

---

## `driver.sh`

### Команды

| Команда | Что делает |
|---------|------------|
| `driver.sh init` | Создаёт `state.json` из `templates/state.json` |
| `driver.sh status` | Печатает текущее состояние + последние 5 событий |
| `driver.sh next` | Выполняет **один** шаг цикла |
| `driver.sh loop [--max-iter N]` | Крутит `next`, пока `phase != done|blocked` |
| `driver.sh set <key> <value>` | Ручное изменение поля `state.json` |
| `driver.sh reset` | Обнуляет `state.json` в шаблон (стирает историю) |
| `driver.sh help` | Краткая справка |

Типичные сценарии:

```bash
# Новый проект
driver.sh init
driver.sh loop

# Продолжить после падения
git pull
driver.sh status    # посмотреть где
driver.sh next      # или loop

# Рестарт после blocked
driver.sh status    # читаем last_error и questions.md
# фиксим руками или правим контракт
driver.sh set .attempts 0
driver.sh set .phase build
driver.sh next
```

### State.json v2

```json
{
  "schema_version": 2,
  "project": "",
  "sprint": 1,
  "phase": "plan",
  "attempts": 0,
  "max_attempts": 3,
  "plan_path": "plans/current.md",
  "contract_path": "contracts/sprint-1.md",
  "report_path": "reports/sprint-1.md",
  "critique_path": "critique/sprint-1.md",
  "last_verdict": null,
  "last_error": null,
  "last_update": "2026-06-09T08:00:00Z",
  "history": [
    {"ts": "...", "event": "plan", "result": "ok", "sprint": 1, "phase": "plan"}
  ]
}
```

`history` — append-only, никогда не чистится автоматически. Полный аудит цикла.

### Переменные окружения

| Var | Default | Что делает |
|-----|---------|------------|
| `OPENCODE_BIN` | `opencode` | путь к opencode CLI |
| `AGENT_TIMEOUT` | `900` | секунд на одного агента (15 min) |
| `STATE_PATH` | `./state.json` | где живёт state |
| `TEMPLATE_DIR` | `<script-dir>/../templates` | где шаблон `state.json` |
| `DRY_RUN` | `0` | `1` = печатать команды, не запускать opencode |

### Cron и systemd

Самый простой cron — пинок каждую минуту, один шаг за раз:

```cron
* * * * * cd /path/to/project && ./scripts/driver.sh loop --max-iter 1 >> driver.log 2>&1
```

Раз в минуту driver сделает один шаг. На `done`/`blocked` — exit 0/1, можно алертить.

Systemd timer — аналогично, но с зависимостями и ретраями. Пример unit'а:

```ini
# /etc/systemd/system/pipeline-driver@.service
[Unit]
Description=Pipeline driver for %i
After=network.target

[Service]
Type=oneshot
User=developer
WorkingDirectory=/home/developer/projects/%i
ExecStart=/home/developer/projects/%i/scripts/driver.sh loop --max-iter 1
StandardOutput=append:/home/developer/projects/%i/driver.log
StandardError=append:/home/developer/projects/%i/driver.log
```

### Поведение TTY vs non-TTY

Driver **по-разному** ведёт себя в зависимости от того, есть ли TTY:

| Режим | Когда | Паузы |
|-------|-------|-------|
| **TTY** | интерактивный терминал | работают, ждут Enter |
| **non-TTY** | cron, systemd, CI, `</dev/null` | auto-skip, логируют причину |

Это by design: cron не умеет ждать Enter.

### Точки паузы

В TTY driver останавливается в этих местах:

| Событие | Сообщение |
|---------|-----------|
| `planner` создал план + `questions.md` | `planner has questions (questions.md) and plan is ready. Review plans/current.md.` |
| `planner` задал вопросы, плана нет | `planner has questions (questions.md) and no plan. Answer them and run 'driver.sh next' to retry.` |
| `verify.sh` fail (2+ попытка) | `verify.sh failed (attempt N/M). See /tmp/driver-verify.log and reports/sprint-N.md.` |
| `critic` FAIL | `critic returned FAIL (attempt N/M). See critique/sprint-N.md. Press Enter to let build retry, or Ctrl-C to stop and fix manually.` |
| `max_attempts` (blocked) | `critic FAIL but max attempts reached. Project is BLOCKED. Review and either fix contract/code or run: driver.sh set .attempts 0 && driver.sh set .phase build && driver.sh next` |

В non-TTY — все паузы auto-skip.

### DRY_RUN

```bash
DRY_RUN=1 driver.sh next
```

Печатает команды, которые **бы** выполнил, но не запускает opencode. Удобно для:
- Проверки state-переходов без траты токенов
- Дебага логики переходов
- Демонстрации цикла коллегам

`verify.sh` при этом запускается (это не opencode, а bash).

---

## Skills

| Skill | Когда использовать |
|-------|---------------------|
| `skills/verify-sprint/` | Написание `verify.sh` и Playwright-тестов |
| `skills/driver-cycle/` | Запуск и отладка `driver.sh`, cron, env vars |

Skills — это контекст для opencode, который активируется автоматически когда задача матчит описание. Чтобы добавить свой skill — следуй `skill_workshop` или формату существующих.

---

## Примеры

### `examples/todo-app/`

Полный рабочий пример: SPA todo-list в одном HTML-файле с localStorage.

Структура:
- `goal.md` — что делаем и для кого
- `plans/current.md` — план с MVP + backlog
- `contracts/sprint-1.md` — критерии для MVP
- `code/index.html` — реализация
- `scripts/ui-test.js` — Playwright-тест (9 проверок)
- `scripts/verify.sh` — статика + UI
- `reports/sprint-1.md` — отчёт build (с упоминанием bug fix)
- `critique/sprint-1.md` — финальный PASS

Используется как референс:
1. Скопировать `goal.md` и адаптировать под свою задачу
2. Посмотреть как оформлен `contracts/sprint-1.md`
3. Скопировать `scripts/ui-test.js` как стартовую точку для UI-тестов

---

## Принципы

1. **Contract first.** Никакого кода до согласованного контракта.
2. **Auto-checkable criteria.** "Работает удобно" — не критерий. "После клика в DOM появляется X" — критерий.
3. **Разделение ролей.** `planner` — продукт, `build` — код, `critic` — проверка. Каждый — отдельный агент с разными permissions.
4. **`critic` не правит код.** Только проверяет. Если нашёл баг — описывает в `critique/sprint-N.md`, не чинит.
5. **`verify.sh` — не LLM.** Bash, exit code, идемпотентность. Для UI — Playwright с реальным chromium.
6. **Минимальные изменения.** Не рефакторим чужой код "по дороге".
7. **Scope строго.** Вне спринта — в `plans/backlog.md`.
8. **State в git.** `state.json` + `plans/` + `contracts/` + `reports/` + `critique/` — всё коммитится. Полная история.
9. **LLM вне петли.** `driver.sh` — bash, не LLM. Каждый шаг детерминирован, перезапускаем.

---

## Roadmap

- [ ] Multi-machine state sync (rsync / git push на каждом step)
- [ ] chrome-devtools MCP как альтернатива playwright
- [ ] Шаблон `examples/auto-cycle/` с готовым mock-тестом для e2e CI
- [ ] Watcher для `questions.md` (alert в Telegram / email)
- [ ] Поддержка parallel sprints (несколько спринтов в работе одновременно)
- [ ] Плагин для VSCode: highlight state.json в status bar

---

## Lessons learned

Из реального прогона на `examples/todo-app/`:

1. **Статический `verify.sh` — иллюзия проверки.** Поймал только "toggle() существует", не "toggle() работает". Playwright поймал реальный bug. **Вывод:** для UI-проектов grep + file exist недостаточно.
2. **Контракт без auto-checkable критериев = MANUAL везде.** `critic` вынужден гадать. **Вывод:** "выглядит хорошо" / "работает удобно" — не критерии.
3. **Цикл build → critic → fix → critic работает.** На todo-app: v1 FAIL → 1 строка фикса → v2 PASS. **Вывод:** retry с обратной связью от `critic` — ключ к autonomous progress.
4. **UI-проект без playwright = бумажная безопасность.** Это самое важное изменение в шаблоне.
5. **LLM в петле → потеря контекста, рост стоимости, нет гарантий.** `driver.sh` снаружи — единственный способ крутить часами.

---

## Антипаттерны

- ❌ **`build` меняет контракт на ходу** ("ой, давайте ещё одну фичу") — нет, контракт согласован ДО реализации
- ❌ **`critic` правит код** ("проще самому починить") — нет, `critic` только проверяет
- ❌ **`planner` лезет в код** ("а давайте ещё функцию добавим") — нет, `planner` только продукт
- ❌ Два `driver.sh loop` параллельно — гонки в `state.json`
- ❌ `driver.sh reset` без бэкапа — история стирается
- ❌ Критерий "работает удобно" / "выглядит хорошо" — не верифицируемо
- ❌ `verify.sh` только на grep — для UI-проектов не ловит визуальные баги
- ❌ Длинная opencode-сессия с надеждой "авось дотянет" — контекст теряется
- ❌ Один агент на всё (без разделения ролей) — нет честной проверки
- ❌ Без playwright для UI-проектов — бумажная безопасность
- ❌ `state.json` в `.gitignore` — теряется история цикла
- ❌ Игнорировать `last_error` в `state.json` — это симптом, не шум

---

## Лицензия

[Apache License 2.0](LICENSE).
