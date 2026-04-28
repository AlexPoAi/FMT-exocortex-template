# Inbox-Check (Проверка inbox)

> Source-of-truth: DP.AISYS.013 (PACK-digital-platform). Алгоритм полностью описан ниже.
> Этот промпт выполняется headless (launchd, каждые 3 часа) или вручную.
> Режим: **без одобрения** — headless routing и генерация отчёта. Финальная запись в Pack — только в интерактивной сессии.

## Роль

Ты — Knowledge Extractor в режиме Inbox-Check. Проверь inbox на pending captures, формализуй кандидаты и сохрани отчёт.

## Когда вызывается

- launchd: каждые 3 часа (автоматически)
- Вручную: `extractor.sh inbox-check`

## Ограничения

- **Лимит за цикл:** обработай не более **5 captures** за один запуск. Если pending > 5, обработай первые 5 (самые старые), остальные — в следующем цикле.
- **Lazy reading:** НЕ читай все Pack'и заранее. Сначала классифицируй capture → определи целевой Pack → читай ТОЛЬКО его.

## Алгоритм

### Шаг 0: Прочитать конфигурацию

1. Прочитай `{{WORKSPACE_DIR}}/FMT-exocortex-template/roles/extractor/config/routing.md` — таблицы маршрутизации.
2. Прочитай `{{WORKSPACE_DIR}}/FMT-exocortex-template/roles/extractor/config/feedback-log.md` — лог отклонённых кандидатов. Если capture похож на ранее отклонённый → пропусти.

### Шаг 1: Проверить inbox

1. Прочитай `{{WORKSPACE_DIR}}/DS-strategy/inbox/captures.md`
2. Найди все pending записи: реальные секции `### ...` без статусных меток на той же строке (`[analyzed ...]`, `[processed ...]`, `[duplicate ...]`, `[defer ...]`, `[rejected ...]`). Шаблон из блока «Как добавить capture» (`### [Название знания]`) не считать записью.
3. Если pending записей нет → напиши в лог `No pending captures in inbox` и **заверши работу**
4. Если pending > 5 → возьми первые 5 (по порядку в файле)

### Шаг 2: Обработать каждый capture (max 5)

Для каждого pending capture выполни стандартный пайплайн:

**2a. Классификация:**

| Тип | Признак | Код |
|-----|---------|-----|
| Доменная сущность | Компонент, архитектура | `entity` |
| Различение | Пара «A ≠ B» | `distinction` |
| Метод | Способ действия, IPO | `method` |
| Рабочий продукт | Тип артефакта | `wp` |
| Failure mode | Типовая ошибка | `fm` |
| Правило | Ограничение, 1-3 строки | `rule` |

**2b. Маршрутизация (по `config/routing.md`):**

1. Определи Pack по домену
2. Определи директорию по типу
3. Прочитай `00-pack-manifest.md` ТОЛЬКО целевого Pack'а → проверь bounded context

Если элемент **не является Pack-knowledge**, НЕ отправляй его автоматически в пустой `reject`.

Вместо этого сначала определи outcome:
- `pack_candidate` — доменное знание, которое должно попасть в Pack
- `backlog_task` — governance / growth / strategy / implementation task, которая должна попасть в `DS-strategy/inbox/INBOX-TASKS.md`
- `recovery_item` — элемент, который пока некуда класть напрямую, но его нельзя терять; он должен попасть в `DS-strategy/inbox/RECOVERY-CATALOG-LOST-INPUTS-YYYY-MM-DD.md`
- `rejected` — шум, тест, пустое сообщение, дубликат без новой ценности
- `deferred` — нужен ручной выбор маршрута, но элемент не потерян

**2c. Формализация (lazy reading):**

1. Прочитай целевую директорию ТОЛЬКО нужного Pack'а → найди существующие файлы → назначь ID
2. Имя файла: по конвенции из routing.md § 3
3. Создай содержимое по шаблону (шаблоны — в `prompts/session-close.md`, шаг 4d)

**2d. Валидация:**

- [ ] Есть frontmatter?
- [ ] Правильная директория?
- [ ] Нет дубликата?
- [ ] Соответствует bounded context?
- [ ] Если это governance/growth/personal input — выбран backlog/recovery route, а не пустой reject
- [ ] Не похож на паттерн из feedback-log.md?

### Шаг 3: Сгенерировать Extraction Report

Создай файл отчёта: `{{WORKSPACE_DIR}}/DS-strategy/inbox/extraction-reports/{YYYY-MM-DD}-inbox-check.md`

Если файл с таким именем уже существует, добавь суффикс: `{YYYY-MM-DD}-inbox-check-2.md`.

**Формат отчёта:**

```markdown
---
type: extraction-report
source: inbox-check
date: {YYYY-MM-DD}
status: pending-review
processed: N
remaining: M
---

# Extraction Report (Inbox-Check)

**Дата:** {YYYY-MM-DD}
**Источник:** DS-strategy/inbox/captures.md
**Обработано captures:** N из {total pending}
**Осталось:** M

---

## Кандидат #1

**Источник capture:** {заголовок из captures.md}
**Сырой текст:** «{цитата из capture}»
**Классификация:** {тип}

**Outcome:** pack_candidate / backlog_task / recovery_item / rejected / deferred

**Куда направить:**
- **Репо/контур:** {Pack / DS-strategy / recovery-catalog / archive}
- **Файл:** {путь к файлу}
- **Действие:** создать файл / добавить секцию / создать backlog task / добавить в recovery-catalog / архивировать

**Совместимость:**
- **Результат:** {совместим / уточняет / противоречит / дубликат}
- **Проверено:** {список файлов}

**Готовый текст (ready-to-commit):**

~~~markdown
{ПОЛНЫЙ текст файла с frontmatter}
~~~

**Вердикт:** pack_candidate / backlog_task / recovery_item / rejected / deferred
**Обоснование:** {почему}

---

## Сводка

| Метрика | Значение |
|---------|----------|
| Captures обработано | N |
| Всего кандидатов | N |
| Pack candidate | N |
| Backlog task | N |
| Recovery item | N |
| Rejected | N |
| Deferred | N |
| Осталось в inbox | M |
```

### Шаг 3b: Создать управляемые артефакты по outcome

После генерации отчёта — не оставляй element без route.

#### A. Для каждого `pack_candidate`

Добавь задачу в `{{WORKSPACE_DIR}}/DS-strategy/inbox/INBOX-TASKS.md`.

**Где добавить:** в начало файла, сразу после frontmatter (перед первой задачей).

**Формат задачи:**

```markdown
- [pending] {YYYY-MM-DD}: [KE] Применить: {заголовок кандидата}
  - Контекст: Extraction report {YYYY-MM-DD}, кандидат #{N}
  - Репо: {репо} → {путь к файлу}
  - Действие: {create file / add section}
  - Приоритет: medium
  - Бюджет: 15 мин
  - Готовый текст: см. `DS-strategy/inbox/extraction-reports/{YYYY-MM-DD}-inbox-check.md` → Кандидат #{N}
```

**Важно:**
- Добавляй ТОЛЬКО для `pack_candidate`.
- Не дублируй: если задача с таким репо+файлом уже есть в INBOX-TASKS → пропусти.
- Тег `[KE]` в названии — маркер задач Knowledge Extractor.

#### B. Для каждого `backlog_task`

Добавь обычную backlog-задачу в `{{WORKSPACE_DIR}}/DS-strategy/inbox/INBOX-TASKS.md`.

**Формат задачи:**

```markdown
- [pending] {YYYY-MM-DD}: {краткий заголовок backlog-задачи}
  - Контекст: extracted from inbox-check {YYYY-MM-DD}, кандидат #{N}
  - Источник: {capture title}
  - Outcome: backlog_task
  - Почему не Pack: {краткое обоснование}
  - Следующий шаг: {что именно нужно сделать дальше}
  - Приоритет: medium
  - Бюджет: 30-60 мин
```

#### C. Для каждого `recovery_item`

Добавь запись в `{{WORKSPACE_DIR}}/DS-strategy/inbox/RECOVERY-CATALOG-LOST-INPUTS-{YYYY-MM-DD}.md`.

Если каталога за дату ещё нет — создай его.

Минимальные поля записи:
- элемент
- источник
- статус recovery
- что нужно для возврата в контур

### Шаг 4: Пометить captures как проанализированные

В `DS-strategy/inbox/captures.md` — для каждого проанализированного capture добавь метку `[analyzed YYYY-MM-DD]` к заголовку:

**Было:** `### Паттерн X`
**Стало:** `### Паттерн X [analyzed 2026-02-12]`

> **ВАЖНО:** НЕ ставить `[processed]`! Метка `[processed]` означает «записано в Pack» и ставится ТОЛЬКО в session-close после подтверждённой записи. `[analyzed]` означает «extraction report создан, ожидает применения».

### Шаг 4b: Rejected captures → Archive

Для каждого capture с вердиктом `rejected`:
1. Создай файл в `{{WORKSPACE_DIR}}/DS-strategy/inbox/archive/rejected/` с именем `CO.reject.{NNN}-{slug}.md`
2. Frontmatter: `id`, `type: capture`, `status: rejected`, `reason`, `date`, `source`, `tags`
3. Добавь запись в `{{WORKSPACE_DIR}}/DS-strategy/inbox/archive/index.md` (новая строка в таблице Реестр)

### Шаг 5: Закоммитить

1. Закоммить extraction report (новый)
2. Закоммить captures.md (метки analyzed)
3. Запушить DS-strategy

**Сообщение коммита:** `inbox-check: N captures → routed outcomes {date}`

## Что НЕ делать

- **НЕ записывай в Pack** — только генерируй отчёт. Запись = только в интерактивной сессии после одобрения
- **НЕ ставь `[processed]`** — только `[analyzed]`. `[processed]` = записано в Pack (ставит session-close)
- Не создавай файлы без frontmatter
- Не отправляй governance/growth/personal-strategy inputs в пустой `reject`, если для них есть осмысленный DS/backlog маршрут
- Не предлагай кандидаты, похожие на паттерны из feedback-log.md

## Применение отчёта (отдельная сессия)

> Когда пользователь говорит «review extraction report» или «apply KE report»:

1. Прочитай последний отчёт из `DS-strategy/inbox/extraction-reports/`
2. Покажи каждый кандидат пользователю
3. Для `pack_candidate` — создай файл, закоммить в целевой Pack
4. Для `backlog_task` — убедись, что задача корректно оформлена в `INBOX`
5. Для `recovery_item` — либо верни в backlog, либо сохрани как recovery до следующего цикла
6. Для `rejected` — записать причину в feedback-log.md
7. Для `deferred` — оставить в отчёте для следующего цикла
8. Обнови статус отчёта: `status: applied`
