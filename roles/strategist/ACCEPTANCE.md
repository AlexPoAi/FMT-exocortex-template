# Acceptance Runbook — Strategist

## Назначение

Этот файл задаёт truthful acceptance-семантику для `Strategist`.

Он нужен, чтобы отделять:
- что агент реально умеет в эксплуатации;
- что остаётся целевой capability;
- когда сценарий считается `pass`, `partial` или `broken`.

## Подтверждённый scope на текущий момент

### Confirmed now

- `WP Gate` и координационный verdict по задаче;
- `morning/day-plan` через canonical open-route;
- `week-review` как weekly scenario с truthful output;
- `note-review` как operational review path;
- координация WeekPlan / SESSION-CONTEXT / INBOX в ритуальном контуре.

### Target capability, not yet proven

- самостоятельный структурный разбор хаоса по нескольким репозиториям;
- end-to-end recovery потерянных входов в единый каталог;
- автономная каталогизация knowledge-layer по Pack'ам и point-hub без отдельного recovery/KE workflow.
- автоматический recovery-return loop, где элементы из recovery-catalog получают weekly/backlog verdict без ручного мостика.

## Verification scenarios

### 1. WP Gate

**Что проверяем:**
- агент truthfully определяет, есть ли задача в плане;
- не открывает работу на ложном основании.

**Pass:**
- найден реальный WP / запись в WeekPlan / разрешённый exception;
- verdict совпадает с фактическим состоянием плана.

**Partial:**
- найден контекст, но verdict требует ручной сверки.

**Broken:**
- агент утверждает, что задача в плане, когда её там нет;
- или блокирует задачу, которая реально уже зафиксирована.

### 2. Morning / Day-Plan

**Что проверяем:**
- агент проходит opening-route;
- создаёт или обновляет утренний артефакт;
- не врёт о success.

**Pass:**
- есть актуальный opening artifact;
- status/state отражают реальный запуск;
- нет false-success.

**Partial:**
- маршрут прошёл частично, но artefact/state требуют ручной коррекции.

**Broken:**
- reported success без артефакта;
- broken prompt path;
- stale snapshot вместо текущего результата.

### 3. Week-Review

**Что проверяем:**
- weekly scenario отрабатывает на реальных данных недели;
- output не пустой и не шаблонный;
- notify/reporting path не ломает смысл результата.

**Pass:**
- weekly summary сформирован;
- данные недели выглядят актуальными;
- weekly notify-contract не сломан.

**Partial:**
- summary есть, но часть данных stale или требует ручной доводки.

**Broken:**
- пустой output;
- broken notify path;
- scenario marked success без содержательного weekly-result.

### 4. Chaos-Structuring Claim

**Что проверяем:**
- может ли Strategist сам выполнить recovery/структуризацию хаотичных входов.

**Pass:**
- создан реальный recovery/structure artifact со статусами, дедупликацией и возвратом живых элементов в рабочий контур.

**Partial:**
- агент смог только приоритизировать уже собранный материал, но не восстановил его сам.

**Broken:**
- claim заявлен, но end-to-end сценарий не выполнен.

> До отдельной живой проверки этот сценарий считать `target capability`, а не подтверждённой способностью.

### 5. Recovery Return Loop

**Что проверяем:**
- читает ли `Strategist` актуальный `RECOVERY-CATALOG-LOST-INPUTS-*`;
- возвращает ли recovered items в weekly triage, `WeekPlan` или backlog;
- не оставляет ли recovery catalog отдельной свалкой без weekly/governance verdict.

**Pass:**
- recovery items отражены в weekly triage;
- для каждого элемента есть явный verdict: `WeekPlan / backlog / keep in recovery`;
- хотя бы один recovered item дошёл до управляемого weekly/backlog контура.

**Partial:**
- recovery catalog прочитан и отражён в повестке, но ещё без полного materialized follow-up в WeekPlan/INBOX.

**Broken:**
- recovery catalog игнорируется;
- recovered items остаются отдельно от weekly/backlog orchestration;
- `Strategist` заявляет weekly triage completed, но recovery layer туда не включён.

## Truthful verdict rules

- `ready` можно ставить только по сценариям, которые проходили живую проверку.
- `partial` означает: часть operational semantics подтверждена, но не весь обещанный scope.
- `broken` означает: сценарий либо не даёт артефакта, либо врёт о результате.
- Если capability не проходила живой сценарий, она должна быть описана как `target`, а не как уже действующая функция агента.
