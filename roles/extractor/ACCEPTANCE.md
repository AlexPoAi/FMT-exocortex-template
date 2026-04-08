# Acceptance Runbook — Extractor

## Назначение

Этот файл задаёт truthful acceptance-семантику для `Extractor`.

Он нужен, чтобы отделять:
- подтверждённый extraction/routing контур;
- target-capability recovery-слоя;
- реальные критерии `pass / partial / broken`.

## Подтверждённый scope на текущий момент

### Confirmed now

- `inbox-check` как headless extraction-report path;
- `on-demand` routing доменных и implementation inputs;
- `session-close` extraction как интерактивный контур предложений;
- фиксация extraction reports и follow-up'ов в DS/Pack слое.

### Target capability, not yet proven

- полноценный end-to-end recovery потерянных входов из нескольких репозиториев и артефактов;
- автоматический возврат recovered elements обратно в устойчивый active WP pipeline;
- надёжная дедупликация recovery-каталога без ручного участия.

## Verification scenarios

### 1. Inbox-Check

**Что проверяем:**
- агент находит реальный inbox source;
- создаёт truthful extraction-report;
- не врёт о количестве и статусе входов.

**Pass:**
- создан extraction report с источниками;
- path resolution корректный;
- если входов нет, verdict truthfully = `SKIP/No pending captures`.

**Partial:**
- report создан, но требует ручной валидации кандидатов или source mapping.

**Broken:**
- `captures.md not found` при реально существующем файле;
- success без extraction report;
- stale или пустой report при наличии входов.

### 2. On-Demand Extraction

**Что проверяем:**
- агент правильно определяет domain vs implementation;
- создаёт candidate artifact в верный контур.

**Pass:**
- есть routing rationale;
- выбран правильный Pack/DS путь;
- candidate artifact согласуется с типом знания.

**Partial:**
- candidate создан, но routing требует ручной коррекции.

**Broken:**
- неверный routing;
- дубликат existing artifact;
- выдуманный или несуществующий путь.

### 3. Session-Close Extraction

**Что проверяем:**
- агент даёт extraction proposals по итогам сессии;
- не пишет knowledge без human approval;
- не путает report и applied result.

**Pass:**
- предложения сформированы;
- approval boundary сохранена;
- report и applied state не смешаны.

**Partial:**
- proposals есть, но статусы или формулировки требуют ручной нормализации.

**Broken:**
- knowledge считается записанным без approval;
- `[processed]`/`[analyzed]` semantics нарушены;
- report не отражает реальное состояние.

### 4. Lost-Input Recovery Claim

**Что проверяем:**
- способен ли Extractor сам собрать потерянные входы в единый recovery-catalog.

**Pass:**
- создан recovery-catalog с дедупликацией, источниками и статусами `new/already tracked/rejected`;
- живые элементы возвращены в рабочий контур.

**Partial:**
- источники собраны, но recovery доведён только до списка кандидатов.

**Broken:**
- capability заявлена, но end-to-end сценарий не выполнен.

> До живой проверки этот сценарий считать `target capability`, а не подтверждённой operational функцией.

## Truthful verdict rules

- `ready` допустим только для сценариев, прошедших живую end-to-end проверку.
- `partial` означает: report/routing слой работает, но full recovery или full apply-loop ещё не доказаны.
- `broken` означает: агент врёт о результате, теряет входы или пишет в неверный контур.
- Если сценарий ещё не проходил живую проверку, capability должна быть описана как `target`.
