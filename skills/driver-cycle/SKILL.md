---
name: driver-cycle
description: Запуск и отладка driver.sh — внешнего цикла plan → build → critic. Используй когда нужно: запустить полный цикл, понять почему застряло, рестартовать с середины, посмотреть историю.
---

# driver-cycle

`scripts/driver.sh` — **внешний state-machine**, который крутит цикл разработки без участия LLM в петле. Переносим между машинами: состояние в `state.json`, восстанавливается из любого места.

## Зачем

Opencode-сессия — не база данных. Падает, решает "всё готово", контекст растёт. Внешний цикл — единственный способ:
- **Автономно работать часами** (cron / systemd пинкуют driver.sh).
- **Пережить падение машины** — state.json в git.
- **Дебажить цикл** — каждое событие в history.

## Фазы

```
[plan] → [build] → [critic] → [build] (retry)
              ↑         |
              |         ↓
              +--- [PASS] ---+
                            ↓
                     [build] (sprint++)
                            ↓
                        [done]
```

| Фаза | Что делает | Кто работает |
|------|------------|--------------|
| `plan` | planner пишет `plans/current.md` | planner-агент |
| `build` | build пишет код + `verify.sh` exit 0 | build-агент + bash |
| `critic` | critic пишет `critique/sprint-N.md` + VERDICT | critic-агент |
| `done` | все спринты PASS'нули | — |
| `blocked` | attempts исчерпаны или парсинг упал | — |

## Команды

### `driver.sh init`
Создаёт `state.json` из `templates/state.json`. Запускается один раз в начале проекта.

### `driver.sh status`
Печатает текущий state + последние 5 событий. Полезно для дебага.

### `driver.sh next`
Выполняет **один** шаг цикла. State обновляется, история пишется. Возвращает 0 если фаза сменилась, 1 если blocked.

### `driver.sh loop [--max-iter N]`
Крутит `next`, пока `phase != done|blocked`. Default max 100 итераций.

### `driver.sh set <key> <value>`
Ручное изменение state.json. Например: `driver.sh set .sprint 2`.

### `driver.sh reset`
Обнуляет state.json в шаблон. **Осторожно** — стирает историю.

## Типичные сценарии

### Новый проект
```bash
cd my-project
git clone <pipeline-template-url> .
# goal.md уже есть или пишем
driver.sh init
driver.sh loop
```

### Продолжить после падения
```bash
cd my-project
git pull
driver.sh status     # посмотреть где остановились
driver.sh next       # или loop
```

### Один спринт вручную (для отладки)
```bash
driver.sh next       # выполнит plan → build → critic один раз
# смотрим отчёт
driver.sh next       # следующий шаг
```

### Рестарт после blocked
```bash
# 1. Читаем questions.md и last_error в state.json
driver.sh status
cat questions.md

# 2. Фиксим руками или пишем комментарий build-агенту
# 3. Сбрасываем attempts и продолжаем
driver.sh set .attempts 0
driver.sh set .phase build
driver.sh next
```

## Защита от зависания

- `AGENT_TIMEOUT` (default 900s = 15 min) — один opencode-агент не может работать дольше.
- Если файл-маркер (`reports/sprint-N.md`, `critique/sprint-N.md`) не появился — driver переходит в `blocked` с явным `last_error`.
- `loop --max-iter N` — защита от бесконечного цикла.

## Cron / systemd

Самый простой cron:
```cron
*/5 * * * * cd /path/to/project && /path/to/driver.sh loop --max-iter 1 >> driver.log 2>&1
```

Раз в 5 минут driver сделает один шаг. Если всё ОК — state продвинется. Если blocked — cron увидит exit 1 и можно алертить.

Systemd timer — аналогично, но с зависимостями и ретраями.

## DRY_RUN

```bash
DRY_RUN=1 driver.sh next
```

Печатает команды, которые **бы** выполнил, но не запускает opencode. Удобно для проверки state-переходов.

## Переменные окружения

| Var | Default | Что делает |
|-----|---------|------------|
| `OPENCODE_BIN` | `opencode` | путь к CLI |
| `AGENT_TIMEOUT` | `900` | секунд на одного агента |
| `STATE_PATH` | `./state.json` | где живёт state |
| `TEMPLATE_DIR` | `<script-dir>/../templates` | где шаблон state.json |
| `DRY_RUN` | `0` | `1` = только печатать |

## Где driver останавливается для человека

В TTY (интерактивный режим) driver ждёт Enter в этих местах:

| Событие | Сообщение |
|---------|-----------|
| planner создал план + задал вопросы | `planner has questions (questions.md) and plan is ready. Review plans/current.md.` |
| planner задал вопросы, плана нет | `planner has questions (questions.md) and no plan. Answer them and run 'driver.sh next' to retry.` |
| verify.sh fail (2+ попытка) | `verify.sh failed (attempt N/M). See /tmp/driver-verify.log and reports/sprint-N.md.` |
| critic FAIL | `critic returned FAIL (attempt N/M). See critique/sprint-N.md. Press Enter to let build retry, or Ctrl-C to stop and fix manually.` |
| max attempts | `critic FAIL but max attempts reached. Project is BLOCKED.` |

В non-TTY (cron/CI) — **все паузы auto-skip**. Это by design: cron не умеет ждать Enter.

## State.json — поля

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

`history` — append-only. Полный лог того, что произошло. Используется для дебага.

## Что мониторить

- `state.json` в git — каждый коммит = снимок прогресса.
- `critique/sprint-*.md` — вердикты и почему.
- `questions.md` — куда агенты пишут, когда застряли.
- `last_error` в state — текущая причина блокировки.

## Антипаттерны

- ❌ Править `state.json` руками без понимания, что делаешь (используй `driver.sh set`).
- ❌ Запускать два `loop` параллельно — будут гонки.
- ❌ Большой `AGENT_TIMEOUT` (>30 min) — если агент завис, лучше fail-fast и рестарт.
- ❌ Игнорировать `last_error` — это симптом, не шум.
- ❌ `reset` без бэкапа — история не восстанавливается.
