# Инструкции для всех репозиториев

> Slim-ядро: триггеры + правила. Детали → memory/protocol-*.md, .claude/rules/, .claude/skills/.

## 1. Архитектура репозиториев

| Тип | Что содержит | Первоисточник |
|-----|-------------|---------------|
| **Base** (Принципы + Форматы) | ZP, FPF, SPF, FMT-* | Да (платформа) |
| **Pack** | Паспорт предметной области | Да (пользователь) |
| **DS** (instrument/governance/surface) | Код, планы, курсы | Нет (производное от Pack) |

**Fallback Chain:** DS → Pack → Base (SPF → FPF → ZP)
**Pack = source-of-truth для доменного знания. DS меняется вслед за Pack.**
Детали типов, именование, измерения: → `memory/repo-type-rules.md`

## 2. ОРЗ-фрактал (Открытие → Работа → Закрытие)

> Три стадии, три масштаба. Пропуск Открытия = незапланированная работа. Пропуск Закрытия = незафиксированный результат.

| Масштаб | Открытие | Работа | Закрытие |
|---------|----------|--------|----------|
| **Сессия** | `memory/protocol-open.md` (любое задание, «открывай сессию») | `memory/protocol-work.md` | manual close по `memory/protocol-close.md` в текущем агенте; `/run-protocol close` только если slash-skill реально доступен |
| **День** | `memory/protocol-open.md` + truthful opening-state («открывай», «открывай день») | Между Day Open и Day Close | manual close по `memory/protocol-close.md` в текущем аутентифицированном агенте; `/run-protocol day-close` только для Claude-среды со slash-skill |
| **Неделя** | — | — | manual week-close по `memory/protocol-close.md`; `/run-protocol week-close` только если slash-skill доступен |

### Блокирующие правила

1. **WP Gate:** ЛЮБОЕ задание → протокол Открытия → ДО начала работы.
2. **Единый маршрут открытия:** `открывай`, `открывай сессию`, `открывай день` всегда проходят через `memory/protocol-open.md` и один русский стартовый экран.
3. **Close provider-agnostic:** `memory/protocol-close.md` выполняется в текущем рабочем агенте. Если `Claude` не залогинен, но `Codex` работает, day-close НЕ блокируется и продолжается через `Codex`. `claude /login` — только для возврата Claude-route.
4. **Slash-route не обязателен:** `/run-protocol *` и `/verify` считать Claude-native convenience layer. Если агент работает в `Codex` или slash-skill недоступен, protocol steps выполняются вручную по файлу `memory/protocol-close.md`/`memory/protocol-open.md` без попытки вызывать slash-команды.
5. **Push:** «заливай» / «запуши» → commit + push без доп. вопросов. Push ДО отчёта Закрытия.
6. **Close:** Триггер Закрытия → протокол Закрытия → выполнить.
7. **Чеклист-верификация (Haiku R23):** Quick Close и Day Close — sub-agent Haiku R23 (context isolation). Исключения: сессия ≤15 мин или без изменений файлов.
8. **Pull-before-Commit / Без Obsidian:** см. §9.

### Протокол Работы (полный → `memory/protocol-work.md`)

**Capture-to-Pack** — на каждом рубеже: есть ли знание для записи? Анонсировать: *«Capture: [что] → [куда]»*. Для KE-знаний сразу писать hot-capture в `DS-strategy/inbox/captures.md`, не оставлять только в памяти сессии. Маршрутизация: правило (1-3 строки) → CLAUDE.md, доменное → Pack, реализационное → DS docs/, урок → memory/.
**Self-correction:** расхождение → немедленно предложить фикс (файл, строка, что изменить).

### Pre-action Gates

| Момент | Проверка |
|--------|---------|
| Начало работы | Какие сервисы (MAP.002) затронуты? |
| Пользовательский сценарий | **UC Gate:** какое обещание (08-use-cases/) затронуто? |
| `git commit` в репо с CLAUDE.md | Прочитать CLAUDE.md репо |
| Архитектурное решение | **АрхГейт** → `/archgate` |
| РП ≥3h | **Priority Gate:** к какому R{N} ведёт? |
| Новый инструмент/агент/система | **IntegrationGate:** тип, контур (L2/L3/L4), роли, продукты, процессы |

## 3. Описания методов (PROCESSES.md)

≤15 мин — не нужен. Внутри системы — `<repo>/PROCESSES.md`. Новая система — сценарий + процессы + данные.

## 4. Memory (Слой 3)

| Ситуация | Читай |
|----------|-------|
| Файлы/репо | `memory/navigation.md` |
| Pack-репо | `memory/repo-type-rules.md` |
| Терминология | `memory/hard-distinctions.md` |
| FPF/SOTA/Роли | `memory/fpf-reference.md`, `memory/sota-reference.md`, `memory/roles.md` |
| Документ/чеклист | `memory/checklists.md` |

Политика: ≤11 файлов. Справочники ≤100 строк. Протоколы ≤150. MEMORY.md ≤100 строк.
Рабочая директория: `{{WORKSPACE_DIR}}/` (не из sub-директорий). `{{WORKSPACE_DIR}}/memory/` = симлинк на auto-memory.

## 5. АрхГейт — ОБЯЗАТЕЛЬНАЯ оценка

> **БЛОКИРУЮЩЕЕ.** Архитектурное решение → `/archgate` → принципы (DP.ARCH.001 §7) → таблица ЭМОГССБ → порог ≥8.
> Чеклист современности: (1) Context Engineering SOTA.002, (2) DDD Strategic SOTA.001, (3) Coupling Model SOTA.011.

## 6. Форматирование → `.claude/rules/formatting.md`

## Различения → `.claude/rules/distinctions.md`

## 7. Обновление этого файла

> **3 слоя:** L1 (§1-§7) = платформа (`update.sh`). L2 (§8) = staging. L3 (§9) = авторское.

- Протоколы → `memory/protocol-*.md`
- Различение (1-3 строки) → `.claude/rules/distinctions.md`
- Форматирование → `.claude/rules/formatting.md`
- Стабильные знания → `memory/*.md`
- Свои правила → §8 (staging) или §9 (авторское)

<!-- PLATFORM-END -->

---

## 8. Staging (обкатка → шаблон)

> Правила на обкатке. Работают → переносятся в шаблон (L1).
> **Перенесено в L1 (20 мар):** UC Gate, межсистемные процессы, чеклист-верификация.

---

## 9. Авторское (только мой IWE)

### Блокирующие (авторские)

- **Pull-before-Commit (DS-strategy):** `git pull --rebase` → модификация → `commit` → `push`.
- **Без Obsidian (DS-strategy):** Просмотр через VS Code.

### Именование

- `DS-strategy` (не `DS-strategy`) — личный governance-хаб
- `{{WORKSPACE_DIR}}/` — рабочая директория

### Read-only репо

> **DS-IT-systems/SystemsSchool_bot** — ⛔ READ-ONLY.
> **DS-IT-systems/aisystant** — ⛔ READ-ONLY.

### README.md (FMT-exocortex-template)

> Изменение структуры — по согласованию с владельцем.

---

*Последнее обновление: 2026-03-24*
