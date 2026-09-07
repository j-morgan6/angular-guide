#!/usr/bin/env bash
# subagent-rules.sh — SubagentStart hook. Subagents inherit no skills, so the
# condensed rule set is injected directly. Mirrors skills/angular-essentials.
# Always exits 0; stdout becomes subagent context.

set -u
cat <<'RULES'
## angular-guide — Rules for Subagents

You are working in a modern Angular workspace (v20+). These are enforced by
hooks; violating them blocks your write.

### Components and templates
- NG001 Never write `standalone: true` — standalone is the default since v20.
- NG002 Never create an `@NgModule`. Use standalone components.
- NG003 Use `@if` / `@for` / `@switch`, never `*ngIf` / `*ngFor` / `*ngSwitch`.
- NG005 Use the `input()` / `output()` / `model()` functions, never the `@Input()` / `@Output()` decorators.
- NG006 Never set `changeDetection: ChangeDetectionStrategy.OnPush` — it is the default in v22.
- NG008 Use `[class.x]` and `[style.x]` bindings, never `ngClass` / `ngStyle`.
- NG009 Use the `host` object in the decorator, never `@HostBinding` / `@HostListener`.
- NG013 Every `@for` needs a `track` expression.

### Dependency injection and services
- NG004 Use `inject()`, never constructor-parameter injection.

### Reactivity
- NG011 Signals have no `mutate()`. Use `set()` or `update()`.
- NG012 Never write a signal from inside `effect()`. Derived state is `computed()`;
  state derived from multiple reactive sources is `linkedSignal()`.
- NG010 Never call `.subscribe()` without `takeUntilDestroyed()`. Prefer the
  `async` pipe, `toSignal()`, or `httpResource()`.

### TypeScript
- NG007 Never use `any`. Use `unknown` and narrow it.

### Security
- NG014 Never bind `[innerHTML]`.
- NG015 Never call `bypassSecurityTrust*`.
- NG016 Never put secrets in `environment*.ts`.

### Workspace-specific
- NG017 Never import `zone.js` in a zoneless workspace — it re-introduces the
  monkey-patching that zoneless exists to remove.
- NG018 Never use Jasmine APIs in a Vitest workspace. Use `vi.fn()` /
  `vi.spyOn()` — TestBed itself is unchanged.

Keep components presentational: HTTP calls, state orchestration, and validation
belong in services, not components.
RULES
exit 0
