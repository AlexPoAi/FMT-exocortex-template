Выполни сценарий Day-Close для роли Стратег (R1).

> **Триггер:** Ручной — по запросу пользователя (`./scripts/strategist.sh day-close`).
> Отдельный файл отчёта НЕ создаётся. Итоги дня войдут в DayPlan следующего утра.

Источник сценария: /Users/alexander/Github/CLAUDE.md → Протокол Day-Close

## Контекст

- **WeekPlan:** /Users/alexander/Github/DS-strategy/current/WeekPlan W*.md (последний по дате)
- **MEMORY:** ~/.claude/projects/-Users-alexander-Github/memory/MEMORY.md
- **SESSION-CONTEXT:** /Users/alexander/Github/DS-strategy/current/SESSION-CONTEXT.md
- **Exocortex backup:** /Users/alexander/Github/DS-strategy/exocortex/

## Truthfulness gate

Это сценарий **закрытия дня**, а не `note-review` и не `day-plan`.

- **НЕ использовать** `fleeting-notes.md`, `unsatisfied-questions.md`, `Notes-Archive.md`, `DayPlan*.md`, если они не нужны прямо для шагов ниже.
- Отсутствие этих файлов **не является blocker** для `day-close`.
- Если отсутствует обязательный вход именно для `day-close` (WeekPlan, MEMORY.md, SESSION-CONTEXT.md, exocortex backup dir, git-репозиторий DS-strategy), остановись быстро и честно сообщи конкретную причину.
- **Никогда не пиши** пользователю `Git: закоммичен и запушен ✅`, `Day-Close завершён` или любой другой success-итог, если ты это не проверил по реальным git/file артефактам.

## Алгоритм

### 1. Сбор коммитов за сегодня

```bash
# Для КАЖДОГО репо в /Users/alexander/Github/:
git -C /Users/alexander/Github/<repo> log --since="today 00:00" --oneline --no-merges
```

- Пройди по ВСЕМ репозиториям в `/Users/alexander/Github/`
- Сгруппируй коммиты по репозиториям
- Сопоставь с РП из недельного плана
- Определи статус каждого затронутого РП: done / partial / not started
- Выведи итоги на экран (не в файл)

### 2. Обновить WeekPlan

Найди текущий `WeekPlan W*.md` в `DS-strategy/current/` и обнови:

- Пометь завершённые РП как **done**
- Обнови статусы partial с описанием прогресса
- Добавь carry-over (что переносится на завтра) — в конец файла
- **НЕ удаляй** ничего — только помечай и дописывай

### 3. Обновить MEMORY.md

Синхронизируй статусы РП в MEMORY.md с обновлённым WeekPlan:
- done → done
- partial → in_progress (с пометкой прогресса)
- Удали завершённые РП из pending, если они в done

### 4. Backup экзокортекса

Скопируй актуальные файлы в `/Users/alexander/Github/DS-strategy/exocortex/`:

```bash
# Корневой CLAUDE.md
cp /Users/alexander/Github/CLAUDE.md /Users/alexander/Github/DS-strategy/exocortex/CLAUDE.md

# Memory (Слой 3)
cp ~/.claude/projects/-Users-alexander-Github/memory/MEMORY.md /Users/alexander/Github/DS-strategy/exocortex/MEMORY.md
cp ~/.claude/projects/-Users-alexander-Github/memory/*.md /Users/alexander/Github/DS-strategy/exocortex/
```

### 5. Закоммитить

- Закоммить все изменения в `DS-strategy` (WeekPlan + MEMORY + SESSION-CONTEXT + exocortex backup, если они реально менялись)
- Запуши
- Перед сообщением пользователю **обязательно проверь**, что:
  - `git status --short` не показывает незакоммиченных целевых изменений,
  - локальный commit действительно создан,
  - `git push` действительно завершился успешно.
- Если любой из этих пунктов не выполнен — **не объявляй успех**, а явно перечисли, что именно не завершилось.

## Правила

- **Ничего не удалять** из WeekPlan — только помечать и дописывать
- **Не создавать отдельный файл отчёта** — итоги дня войдут в DayPlan следующего утра (шаг 1 day-plan)
- Если коммитов за день нет — написать «Нет активности» и всё равно сделать backup
- Выводить итоги на экран для пользователя
- Если сценарий завершился частично, выводить отдельный блок:
  - что выполнено;
  - что не выполнено;
  - какой конкретный блокер мешает считать день закрытым.

## Вывод на экран (шаблон)

```
📋 Day-Close: DD месяца YYYY

Коммиты: N в M репо
- repo-name: N коммитов (краткое описание)

РП обновлены в WeekPlan:
- #N: статус → новый статус

MEMORY.md: синхронизирован ✅
Exocortex backup: скопирован ✅
Git: закоммичен и запушен ✅
```

Результат: обновлённый WeekPlan + MEMORY.md + backup экзокортекса.
