# angular-guide — Design

**Date:** 2026-09-06
**Status:** Approved, ready for implementation planning
**Repo:** `github.com/j-morgan6/angular-guide`

## 1. Purpose

A Claude Code plugin that enforces modern Angular (v20+, signals-first, zoneless)
through deterministic hooks, and supplies the architectural judgment that
Angular's own agent tooling deliberately omits.

## 2. Context

Angular already ships a strong knowledge layer for coding agents:

- `angular/angular` → `skills/dev-skills/angular-developer/` — a SKILL.md plus 40
  reference files (~180KB) covering components, inputs/outputs, host elements,
  naming conventions, signals, `linkedSignal`, `resource`, effects, HttpClient,
  all three form systems, dependency injection, pipes, ARIA, routing, styling,
  animations, and testing.
- `angular/angular` → `skills/dev-skills/angular-new-app/`
- An official MCP server: `npx @angular/cli mcp` — `get_best_practices`,
  `find_examples`, documentation search, OnPush migration analysis.
- `llms.txt` / `llms-full.txt` at angular.dev.
- Prebuilt rule files for Cursor, Copilot, VS Code, JetBrains, Windsurf, Antigravity.

Google maintains all of it and updates it every release. Restating that content
in our own skills would duplicate work and drift out of date within one release
cycle.

What Angular does **not** ship, and what this plugin provides:

1. **Deterministic enforcement.** Skills are advisory — they load only when the
   model elects to load them. Hooks fire on every Write, Edit, and Bash call
   regardless of model cooperation.
2. **Subagent coverage.** Subagents inherit no skills. A `SubagentStart` hook
   injects the condensed rule set into every one.
3. **Version-awareness.** Correct Angular differs sharply between v20, v21, and
   v22. Enforcement must read the workspace before it speaks.
4. **Architectural opinion.** Angular's documentation is deliberately neutral on
   state-management choice, smart/dumb component boundaries, and service
   granularity. Those are exactly the decisions that sink real codebases.
5. **Claude Code packaging.** Angular's skills target skills.sh, Gemini CLI, and
   Antigravity. None of it is a Claude Code plugin.

### Angular version baseline (as of 2026-09)

| Capability | Since | Consequence for enforcement |
|---|---|---|
| Standalone by default | v20 | `standalone: true` is redundant and must be removed |
| Zoneless default for new projects | v21 | `zone.js` imports are a defect in zoneless workspaces |
| `OnPush` is the default strategy | v22 | Explicitly setting `OnPush` is now the anti-pattern |
| Signal Forms stable | v22 | Preferred over Reactive Forms for new forms |
| `resource` / `rxResource` / `httpResource` stable | v22 | Preferred over manual `HttpClient` + subscribe |
| `@Service` decorator | v22 | Preferred over `@Injectable({providedIn: 'root'})` |
| Vitest replaces Karma | v21 | Jasmine spy APIs are a defect in Vitest workspaces |
| `fetch` default HttpClient backend, incremental hydration default | v22 | — |

### Documented AI failure modes this plugin targets

Research into AI-generated Angular identifies these as the most frequent defects,
all traceable to training-data lag toward pre-signals Angular:

- `effect()` used where `computed()` belongs; effects that write signals and
  thrash change detection.
- `*ngIf` / `*ngFor` instead of native control flow.
- Constructor-parameter DI instead of `inject()`.
- Manual `.subscribe()` without teardown — the dominant memory-leak source.
- Business logic, HTTP calls, and validation accumulating inside components.
- Sequential async calls creating request waterfalls.
- Eagerly loading routes that should be lazy.

## 3. Non-goals

- Restating Angular's official reference documentation.
- Supporting Angular below v20 (superseded by the framework's own support policy).
- Bundling or vendoring the official `angular-developer` skill.
- Requiring the Angular CLI MCP server. The plugin must work without it; it may
  mention it, but must not depend on it.
- Formatting or linting concerns already owned by Prettier and ESLint.

## 4. Architecture

Thin skill layer, thick enforcement layer — the inverse of `elixir-phoenix-guide`,
because that plugin's ecosystem had no official agent guidance and Angular's does.

```
angular-guide/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── skills/                       9 skills, each a SKILL.md
├── agents/                       3 read-only review agents
├── hooks/
│   └── hooks.json                native plugin hooks, ${CLAUDE_PLUGIN_ROOT}
├── scripts/
│   ├── detect_project.sh
│   ├── hook-lint.sh
│   ├── bash-guard.sh
│   └── analyze_quality.sh
├── tests/
│   ├── run-tests.sh
│   └── fixtures/
├── CLAUDE.md.template
├── README.md
├── CHANGELOG.md
├── VERSION
└── LICENSE
```

**Three cooperating layers:**

- **Enforcement (hooks)** — deterministic floor. Fires always, including inside
  subagents. Catches the regex-detectable failure modes listed above.
- **Judgment (skills)** — loaded when the model reasons about a decision that
  regex cannot make: which state-management tier, where a boundary belongs,
  whether RxJS is still the right tool.
- **Reference (external)** — Angular's official skills, MCP server, and
  angular.dev. Not vendored. Skills link outward rather than restating.

### Hook delivery

Native plugin hooks via `hooks/hooks.json`, using `${CLAUDE_PLUGIN_ROOT}` to
locate scripts — the pattern established by `ios-from-web-guide`. There is **no**
`install.sh` and no merging into `~/.claude/settings.json`. Installation is
`/plugin marketplace add` plus install; uninstall is clean.

Hook logic lives in real, testable shell scripts, never as inline bash inside
JSON. `elixir-phoenix-guide` embeds 900-character one-liners in its settings
file; at ~30 rules that is unmaintainable and untestable.

### Hook exit-code contract

All hook feedback goes to **stderr**. Claude Code feeds stderr to the model on
exit 2; stdout is reserved for structured JSON hook output.

| Event | Exit 0 | Exit 2 |
|---|---|---|
| `PreToolUse` | allow | block the call, stderr shown to model |
| `PostToolUse` | silent | feed stderr to model, write is **not** undone |
| `SessionStart` / `SubagentStart` | stdout injected as context | — |

Scripts must never exit non-zero for internal errors; any unexpected failure
exits 0 so a plugin bug can never wedge the user's session.

## 5. Component design

### 5.1 `scripts/detect_project.sh` (SessionStart)

Walks up from `$PWD` for `angular.json`. If absent, exits 0 silently — the plugin
is inert outside Angular workspaces. Otherwise parses `angular.json` and
`package.json` and writes `.angular-guide-project.json` at the workspace root.

```json
{
  "plugin_version": "1.0.0",
  "detected_at": "2026-09-06T12:00:00Z",
  "workspace_root": "/path/to/app",
  "angular_version": "22.0.1",
  "angular_major": 22,
  "standalone_default": true,
  "onpush_default": true,
  "signal_forms_available": true,
  "service_decorator_available": true,
  "zoneless": true,
  "test_runner": "vitest",
  "ssr": true,
  "state_lib": "ngrx-signals",
  "package_manager": "pnpm",
  "typescript_strict": true,
  "projects": ["app", "ui-lib"]
}
```

Derivations: `standalone_default` = major ≥ 20; `onpush_default`,
`signal_forms_available`, `service_decorator_available` = major ≥ 22; `zoneless`
= `provideZonelessChangeDetection` present **or** no `zone.js` dependency;
`test_runner` from devDependencies (vitest → karma → jest → none);
`package_manager` from lockfile; `typescript_strict` from `tsconfig.json`;
`state_lib` is one of `ngrx-signals`, `ngrx`, `ngxs`, `akita`, or `none`.

Version resolution order: `package.json` dependency range → lockfile exact
version → `unknown`. On `unknown`, every version-gated rule is **skipped**, never
guessed. Pure bash and `grep`/`sed`; no `jq` dependency. Emits a short summary to
stdout for session context. The cache file is added to the plugin's
`CLAUDE.md.template` gitignore guidance.

### 5.2 `scripts/hook-lint.sh` (Write | Edit)

Two aggregate modes:

- **`pre`** — blocking checks against the *effective post-edit content*. For
  `Write`, the pending content from the tool input JSON. For `Edit`, the on-disk
  file with `old_string` replaced by `new_string`. Checking the pre-edit file
  would miss the very content being introduced.
- **`post`** — warning checks against the file as it now exists on disk, plus
  complexity analysis delegated to `analyze_quality.sh`.

Reads the tool-input JSON from stdin. Loads `.angular-guide-project.json` and
skips any rule whose version gate is unmet. Dispatches by file extension:
`.ts` (component / service / spec / route sub-dispatch), `.html` (template).
Every finding is emitted as `NGxxx: <what> → <fix>` so messages are greppable and
tests can assert on stable IDs.

### 5.3 Hook catalogue

**SessionStart (1)** — `detect_project.sh`.

**PreToolUse / Bash — `bash-guard.sh` (6)**

| ID | Rule |
|---|---|
| BG001 | Block force-push to `main`/`master` |
| BG002 | Block `ng build --prod` (flag removed; use `ng build`) |
| BG003 | Block package-manager invocation mismatching the lockfile |
| BG004 | Block `ng test` without `--watch=false` (hangs an agent session) |
| BG005 | Block deleting `node_modules` together with the lockfile |
| BG006 | Block `ng update --force` |

**PreToolUse / Write|Edit — `hook-lint.sh pre`, blocking (18)**

| ID | Rule | Gate |
|---|---|---|
| NG001 | `standalone: true` in a decorator | ≥ 20 |
| NG002 | `@NgModule` declaration | ≥ 20 |
| NG003 | `*ngIf` / `*ngFor` / `*ngSwitch` → `@if` / `@for` / `@switch` | ≥ 20 |
| NG004 | Constructor-parameter DI → `inject()` | ≥ 20 |
| NG005 | `@Input()` / `@Output()` decorators → `input()` / `output()` | ≥ 20 |
| NG006 | Explicit `changeDetection: ChangeDetectionStrategy.OnPush` (redundant) | ≥ 22 |
| NG007 | `: any` / `as any` / `<any>` → `unknown` | all |
| NG008 | `ngClass` / `ngStyle` → `[class]` / `[style]` | all |
| NG009 | `@HostBinding` / `@HostListener` → `host` object | all |
| NG010 | `.subscribe(` whose `.pipe(...)` chain contains no `takeUntilDestroyed()` | all |
| NG011 | `.mutate(` on a signal → `set` / `update` | all |
| NG012 | `effect()` body writing a signal | all |
| NG013 | `@for` without `track` | ≥ 20 |
| NG014 | `[innerHTML]` binding (XSS) | all |
| NG015 | `bypassSecurityTrust*` | all |
| NG016 | Secret-shaped literal in `environment*.ts` — a string assigned to a key matching `key|secret|token|password|credential` that is not an empty string or a `process.env` reference | all |
| NG017 | `zone.js` import in a zoneless workspace | zoneless |
| NG018 | Jasmine spy API in a Vitest workspace | vitest |

**PostToolUse / Write|Edit — `hook-lint.sh post`, warnings (6)**

| ID | Rule | Gate |
|---|---|---|
| NG101 | Feature route without `loadComponent` / `loadChildren` | all |
| NG102 | `FormBuilder` / `new FormGroup` → prefer Signal Forms | ≥ 22 |
| NG103 | `@Injectable({providedIn: 'root'})` → `@Service` | ≥ 22 |
| NG104 | Static `<img src=` without `ngSrc` / `NgOptimizedImage` | all |
| NG105 | Direct `document.` / `window.` access in a component | all |
| NG106 | Complexity: component LOC, input count, template nesting depth, HTTP call inside a component | all |

**SubagentStart (1)** — inject the condensed rule set, since subagents inherit no
skills. Content is derived from `angular-essentials` to keep the two in step.

Total: 32 rules across 5 hook entries.

### 5.4 Skills (9)

Each SKILL.md follows the established shape: frontmatter (`name`, MANDATORY-worded
`description`, `file_patterns`, `auto_suggest: true`), a numbered
"RULES — Follow these with no exceptions" spine, then Bad/Good pairs. Each skill
names the hook IDs it backs, so the advisory and enforcement layers stay aligned.

| Skill | `file_patterns` | Scope |
|---|---|---|
| `angular-essentials` | `**/*.ts`, `**/*.html` | The non-negotiable spine; every other skill defers to it. Backs NG001–NG009 |
| `signals-essentials` | `**/*.ts` | Decision procedure for `signal` / `computed` / `linkedSignal` / `effect`; anti-pattern catalogue for effect misuse. Backs NG011–NG012 |
| `rxjs-interop` | `**/*.ts` | When RxJS remains correct; `toSignal` / `toObservable` / `rxResource`; `takeUntilDestroyed`; async pipe. Backs NG010 |
| `component-architecture` | `**/*.ts`, `**/*.html` | Smart/dumb split; keeping HTTP, state, and validation out of components; content projection; directive-vs-component. Backs NG105–NG106 |
| `state-management` | `**/*.ts` | Escalation ladder: local signal → service-with-signals → SignalStore / NgRx. Angular ships nothing here |
| `data-loading` | `**/*.ts` | `httpResource` vs `resource` vs `rxResource` vs `HttpClient`; functional interceptors; request-waterfall avoidance |
| `testing-essentials` | `**/*.spec.ts` | Vitest + TestBed; Jasmine→`vi` spy migration; harnesses; what not to test. Backs NG018 |
| `performance-and-zoneless` | `**/*.ts`, `**/*.html` | Zoneless correctness; OnPush-is-default implications; `@defer`; lazy routes; `NgOptimizedImage`. Backs NG006, NG017, NG101, NG104 |
| `project-structure` | `**/*.ts`, `**/angular.json` | v20+ "intent over role" naming; hyphenated filenames; feature folders over type folders; one concept per file |

### 5.5 Agents (3)

Read-only reviewers, dispatched after a unit of work. No write tools.

- `angular-architecture-review` — component/service boundaries, misplaced logic.
- `signals-review` — signal, computed, linkedSignal, and effect usage.
- `angular-project-structure` — layout and naming against the official style guide.

### 5.6 Documentation

`README.md` (what it is, install via marketplace, full skill and hook tables,
explicit statement of how it complements Angular's official skills rather than
replacing them), `CLAUDE.md.template` (project-level rules plus the
`.angular-guide-project.json` gitignore line), `CHANGELOG.md`, `VERSION`.

## 6. Data flow

```
SessionStart
  └─ detect_project.sh → .angular-guide-project.json

Write/Edit (PreToolUse)
  └─ hook-lint.sh pre
       ├─ read tool-input JSON from stdin
       ├─ reconstruct effective post-edit content
       ├─ load project profile, drop version-gated rules
       ├─ dispatch by extension → run NG001–NG018
       └─ finding? stderr + exit 2 (blocked) : exit 0

Write/Edit (PostToolUse)
  └─ hook-lint.sh post → NG101–NG106 + analyze_quality.sh
       └─ finding? stderr + exit 2 (advisory) : exit 0

Bash (PreToolUse)
  └─ bash-guard.sh → BG001–BG006

SubagentStart
  └─ condensed rules → stdout → subagent context
```

## 7. Error handling

- Missing `.angular-guide-project.json` — run every ungated rule, skip every
  gated one. Never guess a version.
- Missing or unparseable `angular.json` — exit 0 silently; the plugin is inert
  outside Angular workspaces.
- Malformed tool-input JSON — exit 0. Never block on a parse failure.
- Any unexpected script error — exit 0. A plugin defect must never wedge a
  session.
- False-positive pressure: every blocking rule needs a fixture proving it fires
  **and** a fixture proving it stays silent on correct code.

## 8. Testing strategy

`tests/run-tests.sh`, modelled on the `ios-from-web-guide` harness: feed fixture
content to a script over stdin, assert exit code and an stderr substring.

- One positive and one negative fixture per rule — 32 rules, ≥ 64 cases.
- `detect_project.sh` fixtures for v20, v21, v22, zoneless, Karma, and
  non-Angular workspaces, asserting the emitted profile JSON.
- Version-gate tests: NG006 must fire on v22 and stay silent on v21; NG017 only
  when `zoneless`; NG018 only when `test_runner` is `vitest`.
- Edit-reconstruction tests: a violation introduced solely by `new_string` must
  be caught, and one removed by an Edit must not be reported.

Non-negotiable. Thirty regex rules without tests are thirty false positives
waiting to fire.

## 9. Versioning and release

Semantic versioning, mirrored across `plugin.json`, `marketplace.json`, and
`VERSION`; `CHANGELOG.md` updated per release. Self-hosted marketplace in
`.claude-plugin/marketplace.json`, matching `elixir-phoenix-guide` and
`ios-from-web-guide`. Angular's release cadence is roughly six-monthly; each
Angular major warrants a review pass over the version gates.

## 10. Sequencing

1. **`angular-guide`** — this spec.
2. **Showcase application** — an Angular 22 app built under this plugin's
   enforcement, with commit history and hook transcripts as evidence. Its own
   spec.
3. **`spring-guide`** — same enforcement-layer architecture, researched fresh;
   Spring's official AI-guidance landscape differs from Angular's and must not be
   assumed. Its own spec.
