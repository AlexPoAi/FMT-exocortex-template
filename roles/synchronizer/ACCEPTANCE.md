# Acceptance Runbook — Synchronizer

## Назначение

Этот файл задаёт truthful acceptance-семантику для `Synchronizer`.

Он нужен, чтобы отделять:
- подтверждённый dispatcher/reporting слой;
- ограниченный verification-harness scope;
- реальные критерии `pass / partial / broken`.

## Подтверждённый scope на текущий момент

### Confirmed now

- `scheduler.sh` как operational dispatcher для `Strategist` и `Extractor`;
- `health-check.sh` как truthful runtime/infra diagnostic;
- `daily-report.sh` как генератор единого status/report verdict;
- Telegram delivery для `daily-report` и `day-close` сценариев;
- refresh runtime/status artifacts перед итоговым отчётом.

### Target capability, not yet proven

- единый acceptance-harness для живой проверки зрелости всех агентов;
- полностью автоматическая verification-matrix с итоговым verdict по каждому агенту без ручной интерпретации;
- безопасный orchestration-loop для capability-testing без отдельной инженерной настройки.

## Verification scenarios

### 1. Daily-Report Dry-Run

**Что проверяем:**
- система может собрать единый truthful report без записи и без побочных эффектов;
- dry-run output отражает текущее состояние среды.

**Pass:**
- `daily-report.sh --dry-run` завершается успешно;
- на выходе есть содержательный отчёт;
- dry-run не пытается писать report/commit/push.

**Partial:**
- отчёт строится, но часть статусов требует ручной сверки.

**Broken:**
- dry-run падает;
- output пустой или явно stale;
- сценарий заявлен безопасным, но вызывает побочные эффекты.

### 2. Health-Check

**Что проверяем:**
- среда получает truthful infra/runtime verdict;
- broken routes, duplicate jobs и major drift подсвечиваются как ошибки.

**Pass:**
- `health-check.sh` даёт понятный verdict;
- критические ошибки среды не скрываются;
- stale-only шум не маскируется под критический сбой.

**Partial:**
- verdict полезен, но часть сигналов всё ещё требует ручной интерпретации.

**Broken:**
- `health-check` врёт о состоянии среды;
- critical issue не поднимается;
- stale-only или cosmetic noise перекрывает реальную картину.

### 3. Status Refresh Consistency

**Что проверяем:**
- `daily-report`, `AGENTS-STATUS`, `SESSION-OPEN` и `RUNTIME-MODE` согласованы между собой;
- Synchronizer не оставляет drift между отчётными слоями.

**Pass:**
- refresh-маршрут обновляет артефакты в одной semantics;
- отчётный слой не противоречит живому runtime verdict.

**Partial:**
- артефакты в целом согласованы, но один из слоёв требует ручного refresh.

**Broken:**
- отчёты расходятся между собой;
- opening/status artifacts stale относительно живого verdict.

### 4. Verification-Harness Claim

**Что проверяем:**
- может ли Synchronizer сам выступать единым acceptance-harness для зрелости агентного слоя.

**Pass:**
- есть повторяемый сценарий, который безопасно запускает verification path и выдаёт итоговый verdict по агенту с проверяемым артефактом.

**Partial:**
- Synchronizer уже даёт dry-run/reporting базу, но полная verification-loop всё ещё требует отдельной инженерной интерпретации.

**Broken:**
- claim заявлен, но живой acceptance-loop не подтверждён.

> До отдельной живой проверки этот сценарий считать `target capability`, а не подтверждённой operational функцией.

## Truthful verdict rules

- `ready` допустим только для сценариев, которые проходили живую проверку.
- `partial` означает: dispatcher/reporting слой подтверждён, но full verification-harness ещё не доказан.
- `broken` означает: Synchronizer врёт о состоянии среды, создаёт drift или ломает safe-run semantics.
- Если verification-capability ещё не проходила живой сценарий, она должна быть описана как `target`.
