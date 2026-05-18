# CODEX.md — FMT adapter for Codex

> This file is the mandatory entry contract for Codex in an IWE workspace.
> It does not replace `CLAUDE.md`. It forces Codex to use the same FMT/IWE route
> as Claude Code.

## Absolute Rule

Codex has no independent IWE route.

For every IWE / Exocortex / DS / Pack task, Codex must first resolve the
canonical FMT route:

1. `CLAUDE.md`
2. `memory/MEMORY.md`
3. `memory/protocol-open.md`
4. the relevant Claude skill under `.claude/skills/`
5. the active WP context in `DS-strategy/current/ACTIVE-WP.md`

If a Claude/FMT route exists, Codex-only fallback is forbidden.

## Start Gate

Before reading project files, running commands, editing files, or planning an
implementation, Codex must stop and name the route checkpoint:

| Field | Required value |
|---|---|
| Active object | day / session / WP / protocol / repo task |
| Canonical source | exact FMT/Claude file, for example `CLAUDE.md` or `.claude/skills/day-open/SKILL.md` |
| Active WP | `WP-NNN` or explicit protocol exception |
| Next transition | the next allowed step under the protocol |

Allowed pre-gate reads are only:

- `CODEX.md`
- `AGENTS.md`
- `CLAUDE.md`
- `memory/MEMORY.md`
- `memory/protocol-open.md`
- `memory/protocol-work.md`
- `memory/protocol-close.md`
- `.claude/skills/<triggered-skill>/SKILL.md`
- `DS-strategy/current/ACTIVE-WP.md`
- the current `WeekPlan`

Reading arbitrary repo files before this checkpoint is route drift.

## WP Gate

For non-trivial work, Codex must use the same WP Gate as Claude:

1. Check whether the task is already in the weekly WP table.
2. If it is not in the plan, stop and run the ritual of agreement.
3. Wait for explicit user approval before materializing a new WP or editing files.
4. Work only inside the approved WP scope.

Exceptions are the same as in `CLAUDE.md`: questions without file changes,
tasks under 15 minutes, and urgent bug fixes. If an exception grows into a
second action, it becomes a WP.

## Ritual Output Shape

For protocol opening / day opening / day closing, Codex must use the Claude Code
monitor shape:

```markdown
## Операция: ...

| Параметр | Значение |
|---|---|
| Роль пользователя | ... |
| Роль Codex | ... |
| Работа | ... |
| РП | ... |
| Класс верификации | ... |
| Метод | ... |
| Оценка бюджета | ... |
| Модель | ... |

**Предупреждение:**
...
```

Do not replace this with a Codex-specific dashboard.

## Forbidden Fallbacks

Codex must not use these as independent permission to act:

- "read-only is always allowed"
- "I can inspect first and ask later"
- "this is just a quick local fix"
- "there is an AGENTS.md rule, so I can skip FMT"
- "the tool failed, so I can choose a different process route"

Tool adapters may differ. The process route may not.

## Conflict Rule

If `CODEX.md`, `AGENTS.md`, local repo rules, or a plugin skill conflict with
`CLAUDE.md` / FMT protocol files, the FMT route wins.

If Codex cannot follow the FMT route because of missing tools, sandbox limits, or
MCP failures, it must report route drift and stop at the current safe boundary.

## Mechanical Close Gate

Commits must include the active `WP-NNN`.

Before close, Codex must:

1. identify only its own changes;
2. avoid reverting another agent's work;
3. run the relevant close protocol;
4. report remaining dirty files explicitly.

This file is platform entry guidance. Stable changes belong in
`FMT-exocortex-template/CODEX.md`; local deviations belong in `extensions/` or
project-specific `CODEX.md`, but never override the FMT gate.
