# Экосистема VK-offee — Инструкция пользования

> Живой документ. Обновляется автоматически после каждого коммита через `update-ecosystem.sh`.
> Последнее обновление: 2026-04-24

---

## 1. Схема экосистемы

```
┌─────────────────────────────────────────────────────────────────┐
│                     OBSIDIAN (Исчезающие заметки)               │
│              ~/Documents/creativ-convector.nocloud/             │
└───────────────────────────┬─────────────────────────────────────┘
                            │ com.obsidian.sync (каждые 15 мин)
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    creativ-convector                             │
│              ~/Github/creativ-convector/                        │
│         Черновики, заметки, файлы сессий стратегирования        │
└───────────────────────────┬─────────────────────────────────────┘
                            │ начать-сессию.sh
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│              DS-strategy/inbox/pending-sessions/                │
│                    Очередь на обработку                         │
└───────────────────────────┬─────────────────────────────────────┘
                            │ session-watcher (каждые 5 мин, launchd)
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│              DS-strategy/inbox/captures.md                      │
│                  Извлечённые знания (inbox)                     │
└──────────┬────────────────────────────────────────┬────────────┘
           │ inbox-check (каждые 3 ч, launchd)      │ rejected
           ▼                                        ▼
┌──────────────────────┐              ┌─────────────────────────┐
│  extraction-reports/ │              │  archive/rejected/      │
│  Отчёты экстрактора  │              │  Governance-контент     │
└──────────┬───────────┘              │  и нераспределённое     │
           │ ты одобряешь             └──────────┬──────────────┘
           ▼                                     │ archive-review
┌──────────────────────┐                         │ (раз в месяц)
│  PACK-cafe-operations│◄────────────────────────┘
│  VK-offee/           │
│  Доменная база знаний│
└──────────────────────┘
           │ com.vkoffee.sync (каждый час)
           ▼
┌──────────────────────┐
│    Google Drive      │
│  Резервная копия     │
└──────────────────────┘
```

---

## 2. Репозитории

| Репо | Тип | Путь | Назначение |
|------|-----|------|-----------|
| `FMT-exocortex-template` | Base/Форматы | `~/Github/FMT-exocortex-template` | Протоколы, агенты, CLAUDE.md — source of truth для формата |
| `VK-offee` | Pack | `~/Github/VK-offee` | Доменная база знаний кофеен VK Coffee — source of truth |
| `DS-strategy` | DS/governance | `~/Github/DS-strategy` | Планы, стратегия, inbox, координация |
| `creativ-convector` | DS/instrument | `~/Github/creativ-convector` | Творческий конвейер: заметки → сессии стратегирования |

---

## 3. Агенты и автоматизации

| Агент | Триггер | Что делает | Лог |
|-------|---------|-----------|-----|
| `com.obsidian.sync` | каждые 15 мин | Синхронизирует Obsidian → creativ-convector | `~/logs/obsidian-sync/` |
| `com.extractor.session-watcher` | каждые 5 мин | Обрабатывает pending-sessions → captures.md | `~/logs/extractor/YYYY-MM-DD.log` |
| `com.extractor.inbox-check` | каждые 3 часа | Проверяет captures.md → extraction-reports/ | `~/logs/extractor/YYYY-MM-DD.log` |
| `com.vkoffee.sync` | каждый час | Синхронизирует VK-offee → Google Drive | `~/Github/VK-offee/.github/scripts/sync.log` |

### Проверить статус агентов

```bash
launchctl list | grep -E "extractor|obsidian|vkoffee"
```

### Перезапустить агента

```bash
# session-watcher
launchctl unload ~/Library/LaunchAgents/com.extractor.session-watcher.plist
launchctl load ~/Library/LaunchAgents/com.extractor.session-watcher.plist

# inbox-check
launchctl unload ~/Library/LaunchAgents/com.extractor.inbox-check.plist
launchctl load ~/Library/LaunchAgents/com.extractor.inbox-check.plist
```

---

## 4. Цепочка стратегирования (пошагово)

```
Шаг 1  Открыть Obsidian → записать заметки в "Исчезающие заметки"
         ↓ автоматически (com.obsidian.sync, 15 мин)
Шаг 2  creativ-convector получает заметки
         ↓ вручную
Шаг 3  cd ~/Github/creativ-convector && bash начать-сессию.sh
         → создаёт файл сессии → кладёт в pending-sessions
         ↓ автоматически (session-watcher, 5 мин)
Шаг 4  Экстрактор обрабатывает сессию → captures.md
         ↓ автоматически (inbox-check, 3 ч) или вручную
Шаг 5  Экстрактор проверяет captures → extraction-reports/
         ↓ ты одобряешь вердикты
Шаг 6  Знания записываются в PACK-cafe-operations
         ↓ автоматически (com.vkoffee.sync, 1 ч)
Шаг 7  PACK синхронизируется на Google Drive
```

---

## 5. Команды терминала

### Запуск из обычного терминала

```bash
# Сессия стратегирования
cd ~/Github/creativ-convector && bash начать-сессию.sh

# Обработать очередь сессий вручную
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/session-watcher.sh

# Проверить inbox вручную
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/extractor.sh inbox-check

# Переобработать архив (раз в месяц)
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/extractor.sh archive-review

# Финальный отчёт цепочки
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/chain-report.sh
```

### Запуск из AI CLI (снимает блокировку вложенных сессий)

```bash
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/ai-run.sh inbox-check
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/ai-run.sh session-watcher
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/ai-run.sh session-close
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/ai-run.sh archive-review
```

### Утренний старт

```bash
# Посмотреть задачи на сегодня
cat ~/Github/DS-strategy/next-actions.md

# Посмотреть что в inbox
cat ~/Github/DS-strategy/inbox/captures.md

# Посмотреть лог за сегодня
cat ~/logs/extractor/$(date +%Y-%m-%d).log
```

### Логи и отчёты

```bash
# Лог экстрактора
tail -f ~/logs/extractor/$(date +%Y-%m-%d).log

# Последний отчёт inbox-check
ls -t ~/Github/DS-strategy/inbox/extraction-reports/*inbox-check* | head -1 | xargs cat

# Последний chain-report
ls -t ~/Github/DS-strategy/inbox/extraction-reports/*chain-report* | head -1 | xargs cat

# Лог Google Drive синхронизации
tail -20 ~/Github/VK-offee/.github/scripts/sync.log
```

---

## 6. Archive layer

Хранилище необработанного материала — знания которые не вошли в Pack.

```
DS-strategy/inbox/archive/
  index.md          ← реестр всего архива (читать здесь)
  raw-sessions/     ← сырые файлы сессий (не обработаны)
  rejected/         ← captures отклонённые экстрактором
  deferred/         ← отложенные (нет подходящего Pack)
```

```bash
# Посмотреть архив
cat ~/Github/DS-strategy/inbox/archive/index.md

# Запустить переобработку архива
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/ai-run.sh archive-review
```

---

## 7. PACK-cafe-operations — структура базы знаний

```
PACK-cafe-operations/
  00-pack-manifest.md     ← что входит в scope Pack
  01-domain-contract/     ← принципы и ограничения домена
  02-domain-entities/     ← сущности (CO.ENTITY.*)
  03-methods/             ← методы и регламенты (CO.METHOD.*)
  04-work-products/       ← рабочие продукты (CO.WP.*)
  05-failure-modes/       ← типовые ошибки (CO.FM.*)
  06-sota/                ← состояние знаний
  07-map/                 ← карта домена
```

---

## 8. Как обновляется этот файл

После каждого `close-task.sh` автоматически запускается `update-ecosystem.sh` который:
- Проверяет новые скрипты в `roles/extractor/scripts/`
- Проверяет новые промпты в `roles/extractor/prompts/`
- Обновляет дату последнего обновления

Обновить вручную:
```bash
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/update-ecosystem.sh
```
