# Экстрактор (Knowledge Extractor, R2)

> Извлекает, формализует и маршрутизирует знания в Pack-репозитории и DS docs/.

## Что делает

При закрытии сессии или по запросу — находит знания, идеи и lost inputs, формализует и предлагает записать в правильное место. **Целевой routing больше не должен сводиться к бинарному `Pack / reject`:**
- доменное знание → `Pack`
- governance / growth / personal strategy → `DS-strategy` backlog или recovery-контур
- реализационное знание → `DS docs/`
- пустые/тестовые сообщения → `reject`

Пользователь всегда одобряет перед финальной записью в Pack.

> Truthful note: routing и extraction-report контур подтверждены практикой. Но full-loop модель `input -> classification -> target route -> artifact -> tracked status` ещё не доведена до конца: governance/growth/personal inputs уже не должны тихо теряться на уровне `inbox-check`, но полный end-to-end return loop через `Strategist` и weekly/backlog orchestration ещё не доказан живым сценарием.

## Сценарии

| Сценарий | Триггер | Режим |
|----------|---------|-------|
| **Session-Close** | Закрытие сессии (протокол Close) | Интерактивный |
| **On-Demand** | «Запиши это в Pack» | Интерактивный |
| **Knowledge Audit** | «Аудит Pack» / ежемесячно | Интерактивный |
| **Inbox-Check** | launchd каждые 3ч (опционально) | Headless (отчёт) |

## Acceptance

- [ACCEPTANCE.md](./ACCEPTANCE.md) — truthful runbook для сценариев `pass / partial / broken`

Короткая семантика:
- `inbox-check`, `on-demand`, `session-close` — confirmed operational scope
- `lost-input recovery` — пока target capability, не verified-by-default

## Когда подключать

- Создал первый Pack (PACK-{твоя-область})
- Работаешь с Claude Code регулярно (≥3 сессии/неделю)
- Хочешь автоматически фиксировать знания

## Установка

### 1. Настрой маршрутизацию

Отредактируй `config/routing.md` — добавь свои Pack'и:

```markdown
| Домен | Pack | Префикс | Путь |
|-------|------|---------|------|
| Мой домен | PACK-my-domain | MD | {{WORKSPACE_DIR}}/PACK-my-domain/pack/my-domain/ |
```

### 2. (Опционально) Установи автоматический inbox-check

```bash
cd {{WORKSPACE_DIR}}/FMT-exocortex-template/roles/extractor
bash install.sh
```

Это установит launchd-агент для проверки inbox каждые 3 часа.

### 3. Ручной запуск

```bash
# Inbox-check (без launchd)
bash {{WORKSPACE_DIR}}/FMT-exocortex-template/roles/extractor/scripts/extractor.sh inbox-check

# Knowledge Audit
bash {{WORKSPACE_DIR}}/FMT-exocortex-template/roles/extractor/scripts/extractor.sh audit
```

## Как работает

```
Knowledge Extraction Pipeline:

  Обнаружение → Классификация → Маршрутизация → Формализация → Валидация → Одобрение → Запись

  1. Найти знания (captures + пропущенные инсайты)
  2. Определить тип (entity, distinction, method, fm, wp, rule)
  3. Определить target route:
     ├─ domain knowledge → Pack по домену (routing.md §1-4)
     ├─ implementation knowledge → DS docs/ по системе (routing.md §5)
     ├─ governance / growth / personal strategy → backlog task / recovery item
     └─ noise / test / duplicate → reject
 4. Создать управляемый артефакт:
     ├─ Pack → candidate card / SPF text
     ├─ DS → docs candidate
     └─ backlog/recovery → запись в `INBOX` или recovery-catalog
  5. Выполнить post-check:
     ├─ report существует
     ├─ `pack_candidate/backlog_task` дали след в `INBOX`
     ├─ `recovery_item` дал recovery-catalog
     └─ `rejected` дал archive entry
  6. Проверить: нет ли дубликатов и противоречий
  7. Показать Extraction Report пользователю
  8. Записать только одобренное или правильно routed
```

## Файлы

| Файл | Назначение |
|------|-----------|
| `config/routing.md` | Таблицы маршрутизации (Pack'и, типы, директории) |
| `config/feedback-log.md` | Лог отклонённых кандидатов (не предлагать повторно) |
| `prompts/session-close.md` | Промпт: экстракция при закрытии сессии |
| `prompts/on-demand.md` | Промпт: экстракция по запросу |
| `prompts/inbox-check.md` | Промпт: headless проверка inbox |
| `prompts/knowledge-audit.md` | Промпт: аудит Pack'ов |
| `scripts/extractor.sh` | Скрипт запуска (аналог strategist.sh) |
| `scripts/launchd/` | launchd plist для inbox-check |

## Принципы

1. **Human-in-the-loop:** Экстрактор предлагает, не записывает без одобрения
2. **Один пайплайн:** Все сценарии используют classify → route → formalize → validate
3. **Тест универсальности:** Можно использовать в другом контексте? Нет → это не обязательно мусор; сначала реши, это governance/backlog/recovery item или действительно reject
4. **Lazy reading:** Inbox-check читает только целевой Pack, не все сразу
5. **Truthful scope:** Если recovery-сценарий не доведён до end-to-end, Экстрактор должен выдавать отчёт и кандидаты, а не делать вид, что контур уже полностью восстановлен
6. **Не терять governance-inputs:** growth, strategy, personal-owner tasks и backlog items не должны уходить в `reject`, если для них существует осмысленный DS/backlog маршрут
7. **Report не считается успехом сам по себе:** `inbox-check` должен оставлять проверяемый след в `INBOX`, recovery-catalog или archive, иначе сценарий считается broken

---

*Source-of-truth: DP.AISYS.013 (PACK-digital-platform)*
