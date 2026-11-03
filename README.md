# angular-guide

A Claude Code plugin that enforces modern Angular (v20+, with the current v22 defaults)
through deterministic hooks, not just advice. It ships nine skills, thirty rules wired
into `PreToolUse`/`PostToolUse`/`Bash` hooks, and three read-only review agents.

## What this is

`angular-guide` watches every `Write`, `Edit`, and `Bash` call Claude Code makes in an
Angular workspace and blocks or flags the patterns that keep showing up when a model
writes pre-v20 Angular: `@NgModule`, `*ngIf`/`*ngFor`, constructor injection, decorator
`@Input()`/`@Output()`, unbounded `.subscribe()`, and a handful of Angular-specific
footguns in Bash (a force-push to `main`, `ng build --prod`, deleting a lockfile).

**This plugin complements Angular's own tooling — it does not replace or duplicate it.**
Specifically:

- Angular's official agent skill — `angular/angular` → [`skills/dev-skills/angular-developer/`](https://github.com/angular/angular/tree/main/skills/dev-skills/angular-developer)
- Angular's CLI MCP server — `npx @angular/cli mcp`
- Angular's own model-readable reference — [`angular.dev/llms.txt`](https://angular.dev/llms.txt)

Use all of them together. This plugin's skills deliberately do not restate Angular's
reference documentation — each one says so and points back to these three sources for
everything outside the specific rules it enforces.

## Why it exists

Angular's official agent skill is advisory: the model has to elect to load it, and
nothing stops it from writing legacy patterns anyway, especially under time pressure or
mid-refactor. And **subagents inherit no skills at all** — a `Task`-dispatched subagent
in Claude Code starts with none of this context, however carefully the parent session
was primed.

This plugin's rules fire on every `Write`, `Edit`, and `Bash` call regardless of which
skill (if any) the model chose to load, and regardless of whether the call came from the
main session or a subagent — in an Angular workspace, a `SubagentStart` hook injects the
condensed blocking rule set (the NG0xx rules this workspace's version enables) directly
into every subagent's context, and the same `PreToolUse` hooks still run underneath it.

## Requirements

- Angular v20 or later (some rules are gated further to v21/v22 — see [Version
  awareness](#version-awareness))
- `bash` (3.2+ — the macOS-shipped version is fine; no bash 4 features are used)
- `python3` (used for JSON parsing and the multiline/balanced-paren checks that plain
  `grep` can't express)
- **No `jq`.** Nothing in this plugin depends on it.

## Installation

```
/plugin marketplace add j-morgan6/angular-guide
```

Then install `angular-guide` through Claude Code's plugin manager.

**There is no `install.sh`, and nothing is ever written to `~/.claude/settings.json`.**
Hooks are delivered natively through this plugin's own `hooks/hooks.json`, using
`${CLAUDE_PLUGIN_ROOT}` to reference the plugin's own scripts. Installing or removing the
plugin is the entire install/uninstall story — there is no separate step that touches
your global or project Claude Code settings.

## The 9 skills

Each skill is model-invoked: its frontmatter `paths` globs limit it to sessions working
on matching files, and within that the model elects whether to consult it. Nothing forces
that election — which is exactly the gap the hooks in this plugin exist to backstop.

| Skill | `paths` | Covers |
|---|---|---|
| `angular-essentials` | any `.ts` / `.html` | Standalone-by-default, no `@NgModule`, native control flow, `inject()`, signal `input()`/`output()`/`model()`, no `any`, native class/style bindings, the `host` object, no `[innerHTML]`/`bypassSecurityTrust*` |
| `signals-essentials` | any `.ts` | Choosing `computed()` vs. `linkedSignal()` vs. `effect()`; effects never write signals; `resource()` family for async state |
| `rxjs-interop` | any `.ts` | When to still reach for RxJS vs. signals; teardown on every manual `.subscribe()`; converting to signals at the boundary with `toSignal()` |
| `component-architecture` | `*.component.ts`, `.html` | Keeping HTTP and validation out of components; presentational vs. container split; the ~200-line / ~8-input size ceiling; no direct `document`/`window` |
| `state-management` | `*.store.ts`, `*.service.ts`, any `.ts` | The escalation ladder from component state → service with signals → `@ngrx/signals` / NgRx, matched to actual complexity |
| `data-loading` | `*.service.ts`, any `.ts` | `httpResource()` for signal-keyed reads vs. `HttpClient` for commands; parallel independent requests; interceptors as functions; error handling at the right boundary |
| `testing-essentials` | `*.spec.ts`, `*.test.ts` | Vitest as the default runner (`vi.fn()`/`vi.spyOn()`, never Jasmine) |
| `performance-and-zoneless` | any `.ts` / `.html` | No explicit `OnPush` on v22+, no `zone.js` in a zoneless workspace, mandatory `@for` `track`, lazy-loaded routes, `NgOptimizedImage` |
| `project-structure` | any `.ts`, `angular.json` | Hyphenated, intent-named files; feature-first directories over type-first ones |

## The 30 rules

Every rule's ID, gate, and wording lives in one place, `scripts/rules.py`. The tables
below, the rule list in `CLAUDE.md.template`, the hook messages, and the rules given to
subagents are all rendered from it. After changing a rule, run
`python3 tools/gen_docs.py`; the test suite fails if the generated docs are stale.

### BG001–BG006 — Bash guard (`PreToolUse` on `Bash`)

Runs before any Bash command, **only inside an Angular workspace** (one with a profile —
see [Version awareness](#version-awareness)). The command line is parsed, not
pattern-matched: it is split into simple commands at `;`, `&&`, `||`, `|` and newlines,
quoted text stays a single argument, wrappers (`sudo`, `env`, `time`, `npx`/`bunx`,
`pnpm`/`yarn exec`, `npm exec`) are removed, and a `bash -c "..."` string is parsed in
turn. So `echo 'rm -rf yarn.lock'` or a commit message that mentions `ng build --prod`
never matches, and a `--force` belonging to one command is never credited to another.

<!-- generated:rules-bash -->
| ID | Catches | Fix |
|---|---|---|
| BG001 | A force push (`--force`, `-f`, a combined short flag like `-fu`, or a `+ref` refspec) whose destination is `main`/`master`. The *destination* side of a `src:dst` refspec decides (so `main:feature/x` is not flagged); `refs/heads/main` counts as `main`; `HEAD`, or no refspec at all, means the checked-out branch (`git symbolic-ref --short -q HEAD`, honouring `git -C <dir>`). | Use `--force-with-lease`, and push to a feature branch instead. |
| BG002 | `ng build --prod` | Run `ng build`. Production is the default configuration. |
| BG003 | A package-manager `install`/`i`/`add`/`ci` with a manager other than the one the workspace's lockfile implies (the profile's `package_manager`). | Use the manager the lockfile names — mixing package managers produces a second lockfile and divergent dependency trees. |
| BG004 | `ng test` without a flag that prevents watch mode (`--watch=false`, `--watch false`, `--no-watch`, `--run`, or `--ci`) — and `npm test`, `npm run test`, `pnpm test` or `yarn test` when the workspace's `test` script runs `ng test` without one and none is passed through. | Run `ng test --watch=false` (Karma) or `ng test --run` (Vitest); through a package manager, pass it on: `npm test -- --watch=false`. |
| BG005 | `rm` with a lockfile (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `bun.lockb`) among its arguments. | Delete `node_modules` alone and reinstall. Only remove the lockfile when deliberately re-resolving the whole dependency tree. |
| BG006 | `ng update --force` | Resolve the reported incompatibilities, or update one package at a time. Run `ng update` without `--force` first to see what it objects to. |
<!-- /generated:rules-bash -->

Commands built at runtime — `$(...)`, backticks, `eval`, variables holding a command —
are not expanded, so a rule inside one is not seen.

### NG001–NG018 — blocking checks (`PreToolUse` on `Write`/`Edit`, `hook-lint.sh pre`)

Each rule runs twice: against the file **before** the change (what is on disk, or nothing
for a new file) and **after** it (a `Write`'s pending `content`, or the on-disk file with
an `Edit`'s `old_string` replaced by `new_string`). A rule blocks only when it matches
**more times after the change than before** — so an edit that introduces a violation
into existing context is caught before it's written, but an unrelated edit to a file that
already breaks a rule goes through, and adding another instance to such a file is
blocked with a note saying how many were already there. A finding exits 2 and blocks the
write. Only `.ts` and `.html` files are considered; comments (`//`, `/* */`, `<!-- -->`,
including inside template-literal backticks) are stripped before matching. The matchers
live in `scripts/lint.py`, one `check_ngNNN()` function each; their wording and gates are
in `scripts/rules.py`.

<!-- generated:rules-pre -->
| ID | Catches | Fix | Gate |
|---|---|---|---|
| NG001 | `standalone: true` in a decorator | Delete the property. Standalone is the default since Angular v20 — writing it is redundant and signals a pre-v20 mental model. | v20+ |
| NG002 | `@NgModule` | Use standalone components. Put shared providers in `providers` at bootstrap or on a route, and import components directly via the `imports` array. | v20+ |
| NG003 | `*ngIf` / `*ngFor` / `*ngSwitch` / `[ngSwitch]` | Use native control flow — `@if (cond) { }`, `@for (x of xs; track x.id) { }`, `@switch (v) { @case (a) { } }`. It needs no imports, is faster, and is the only supported form going forward. | v20+ |
| NG004 | Constructor-parameter DI (`constructor(private x: T)`) — **only inside a file that already carries an Angular class decorator** (`@Component`, `@Directive`, `@Injectable`, `@Service`, `@Pipe`, or `@NgModule`); a plain value class like `Money` with a `constructor(private amount: number)` is not flagged. | Use the `inject()` function at field level: `private readonly http = inject(HttpClient);` | v20+ |
| NG005 | `@Input()` / `@Output()` decorators | Use the signal-based functions — `input()` / `input.required()`, `output()`, `model()`: | v20+ |
| NG006 | Explicit `changeDetection: ChangeDetectionStrategy.OnPush` | Delete the property and its import. OnPush is the default strategy in Angular v22 — setting it explicitly is now noise. | v22+ |
| NG007 | `any` in a `.ts` file (as a type annotation, `as any`, or `<any>`), not the word inside a string | Use `unknown` when the type is genuinely uncertain and narrow it, or give the value its real type. `any` disables every check TypeScript exists to provide. | — |
| NG008 | `[ngClass]` / `[ngStyle]` (attribute or property-binding form) | Use native bindings — `[class.active]="isActive()"`, `[style.width.px]="w()"`, or `[class]="classRecord()"`. They need no import and avoid an extra directive instance per element. | — |
| NG009 | `@HostBinding` / `@HostListener` decorators | Use the `host` object in the decorator metadata: `@Component({ host: { "[class.active]": "isActive()", "(click)": "onClick($event)" } })` | — |
| NG010 | `.subscribe()` whose call chain (walked back at bracket depth 0 to the previous `;`, `,`, `=>`, or unmatched opener, so arrow functions inside earlier operators don't cut it short) contains none of `takeUntilDestroyed`, `takeUntil(`, `take(`, `first(`, `firstValueFrom`, `lastValueFrom` — matched as plain substrings, and skipped entirely in `.spec.ts`/`.test.ts` files. | Prefer not subscribing at all — use the `async` pipe, `toSignal(obs$)`, or `httpResource()`. For a one-shot HTTP command, `await firstValueFrom(...)`. When you must subscribe, add teardown: `obs$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe(...)` | — |
| NG011 | `.mutate(` on a signal | Use `set()` with a new value, or `update()` with a pure transform: `this.items.update((xs) => [...xs, item]);` | — |
| NG012 | `effect(...)` whose body (balanced-paren extracted, so it correctly spans nested calls) contains a one-argument `.set(` or `.update(` outside an `untracked(...)` callback — a two-argument `.set(k, v)` is a `Map`/`HttpParams`/`URLSearchParams`, not a signal | Derived state belongs in `computed()`; writable state derived from other signals belongs in `linkedSignal()`. Effects are for side effects that leave the reactive graph — logging, third-party DOM, analytics. | — |
| NG013 | `@for (...)` whose balanced-paren clause contains no `track` — the clause is extracted by counting parens, not by matching to the first `)`, so `@for (x of items(); track x.id)` is correctly **not** flagged despite the inner `items()` call. | Add a stable identity — `@for (item of items(); track item.id) { }`. `track` is mandatory; without it Angular cannot reuse DOM nodes and rebuilds the whole list on every change. | v20+ |
| NG014 | `[innerHTML]` / `[outerHTML]` bindings | Render text with interpolation, or compose real components. If you must render untrusted markup, sanitize it server-side and render through a vetted component — Angular sanitizes `[innerHTML]` but the pattern still invites XSS as soon as someone reaches for `bypassSecurityTrust*`. | — |
| NG015 | Any `bypassSecurityTrust*` call | This disables Angular XSS protection for that value. Sanitize upstream and render normally. If a genuine trusted-value case exists, it belongs in one reviewed, narrowly-scoped helper — never inline in a component. | — |
| NG016 | In a file under an `environments?/` directory or named `environment*.ts`, a string literal assigned to a key whose last word is `password`/`secret`/`credential` (any non-empty value), or `key`/`token` (only a value that looks issued: a known secret prefix like `sk_live_`/`ghp_`/`AKIA`, or 20+ high-entropy characters). URLs, lines that read `process.env`/`import.meta.env`, and browser keys that are public by design (`AIza…`, Stripe `pk_…`) are skipped — so `storageKey: "app-theme"` passes. | `environment.ts` is compiled into the browser bundle — anything in it is public. Move the secret behind your backend and have the client call your API. Build-time injection does not help; the value still ships. | — |
| NG017 | An `import`/`require` of `zone.js` | Remove the import. This app runs with `provideZonelessChangeDetection()`; loading zone.js re-introduces monkey-patching of every async API and negates the benefit. | zoneless workspaces |
| NG018 | A `jasmine.*` reference in a `.ts` file | Use the Vitest equivalents — `vi.fn()` for `jasmine.createSpy()`, `vi.spyOn()` for `spyOn()`, `expect.objectContaining()` for `jasmine.objectContaining()`. TestBed itself is unchanged. | Vitest workspaces |
<!-- /generated:rules-pre -->

### NG101–NG106 — advisory checks (`PostToolUse` on `Write`/`Edit`, `hook-lint.sh post`)

Run against the file **already written to disk**. A finding exits 2 and is shown to the
model, but the write already happened — nothing is undone.

<!-- generated:rules-post -->
| ID | Catches | Fix | Gate |
|---|---|---|---|
| NG101 | A route object in a file whose path matches `routes?.ts`/`.routes.ts`/contains `routing`, with an eager `component: SomeComponent` reference | Lazy-load it so the feature leaves the initial bundle: `{ path: "admin", loadComponent: () => import("./admin/admin-page").then((m) => m.AdminPage) }` | — |
| NG102 | `FormBuilder` / `new FormGroup` / `fb.group(` in a non-spec `.ts` file | Prefer Signal Forms for new forms — form state is signals, so it composes with `computed()` and needs no `valueChanges` subscription. Staying on Reactive Forms is correct when extending an existing Reactive Forms screen; starting a new one there is not. | v22+ |
| NG103 | `@Injectable({ providedIn: 'root' })`, including when the object spans several lines | Use the `@Service()` decorator — it is the same root-provided singleton with less ceremony. | v22+ |
| NG104 | A static `<img ... src="...">` with no `NgOptimizedImage`, including a tag Prettier has wrapped across lines. | Import `NgOptimizedImage` and use `ngSrc` with explicit `width`/`height` (or `fill`): `<img ngSrc="/assets/hero.png" width="800" height="600" alt="Hero">` | — |
| NG105 | Direct `document.`/`window.` access (the globals — `this.document` from `inject(DOCUMENT)` is not flagged) in a file that is a component — the path ends `.component.ts`, **or** its (comment-stripped) content contains `@Component` — skipped entirely in `.spec.ts`/`.test.ts` files. | Use `viewChild()` signal queries for element access, `afterRenderEffect()` for DOM work that must run post-render, and inject `DOCUMENT` rather than reaching for the global. Direct globals break SSR, where neither exists. | — |
| NG106 | Structural complexity in a component file (same `.component.ts`-or-`@Component` test as NG105; also runnable standalone as `analyze_quality.sh`): an `HttpClient` reference, more than ~200 non-blank lines, or more than ~8 `input()`/`input.required()` declarations — skipped entirely in `.spec.ts`/`.test.ts` files. | Move HTTP into a service; split the component; collapse many scalar inputs into one object input. | — |
<!-- /generated:rules-post -->

## Version awareness

Every rule is gated on a workspace profile built by `scripts/ag_profile.py`. It walks
up for `angular.json`, reads the Angular version from `package.json` (falling back to
`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, or `bun.lock` if `package.json`
only has a range), and caches the result in the plugin's data directory
(`$CLAUDE_PLUGIN_DATA/profiles/`, or `$XDG_CACHE_HOME/angular-guide/profiles/` on Claude
Code versions without it). **Nothing is written into your repository.**

`SessionStart` builds the profile and prints a summary into the session. In a monorepo
started at the repo root it also searches up to six levels down for a single
`angular.json`, and remembers that root for later hooks. Every other hook resolves the
profile from the file or directory it is working on, detecting it on first use and
re-detecting it whenever `package.json`, `angular.json`, `tsconfig.json`, or a lockfile
is newer than the cache — so an `ng update` mid-session takes effect on the next write.

A profile looks like this:

```json
{
  "plugin_version": "1.0.0",
  "detected_at": "2026-09-06T00:00:00Z",
  "workspace_root": "/path/to/workspace",
  "angular_version": "22.0.1",
  "angular_major": 22,
  "standalone_default": true,
  "onpush_default": true,
  "signal_forms_available": true,
  "service_decorator_available": true,
  "zoneless": true,
  "test_runner": "vitest",
  "ssr": false,
  "state_lib": "none",
  "package_manager": "npm",
  "typescript_strict": true,
  "projects": ["my-app"]
}
```

**An unknown version skips gated rules — it never guesses.** If `@angular/core` can't be
resolved from `package.json` or any recognized lockfile, `angular_major` is `"unknown"`
and every boolean gate derived from it (`standalone_default`, `onpush_default`,
`signal_forms_available`, `service_decorator_available`) is `false`, so NG001, NG002,
NG006, NG013, NG102, and NG103 simply don't fire rather than firing on a guess. The same
applies to `zoneless` (NG017) and `test_runner` (NG018): each rule is gated on the
specific field the profile reports, not inferred.

## Running the tests

```
bash tests/run-tests.sh
```

The suite is self-contained bash + python3 (no `jq`, no external dependencies) and
exercises `detect_project.sh`, `hook-lint.sh` (both modes), `bash-guard.sh`,
`subagent-rules.sh`, the `hooks/hooks.json` wiring, and every skill's frontmatter shape.
Drift checks fail the build if the generated docs are stale (`R2`), if a skill cites a
rule ID `rules.py` doesn't define (`S2`), or if `rules.py` and the implementations in
`lint.py`/`guard.py` disagree about which rules exist (`S3`).

## Tuning

Don't edit the plugin's files to change its behaviour: an installed plugin lives in
`~/.claude/plugins/cache/`, and an update replaces that copy.

### Turn a rule off everywhere

- **Just for you:** run `/plugin configure angular-guide@angular-guide` and list the IDs
  under **Disabled rules**, e.g. `NG007, NG010, BG001`.
- **For everyone on a project:** set `ANGULAR_GUIDE_DISABLED_RULES` in the project's
  committed `.claude/settings.json`:

  ```json
  { "env": { "ANGULAR_GUIDE_DISABLED_RULES": "NG010, NG102" } }
  ```

Both take NG and BG IDs, separated by commas or spaces, in any case, and the two lists
add together. A disabled rule never blocks or warns, and is left out of the rules given
to subagents.

### Ignore one spot

Put a directive in a comment, naming the rule IDs and a reason after `--`:

```ts
// angular-guide-ignore-next-line NG010 -- app-lifetime websocket, torn down with the app
this.socket$.subscribe((m) => this.dispatch(m));

const raw: any = legacyLib(); // angular-guide-ignore-line NG007 -- untyped third-party API
```

```html
<!-- angular-guide-ignore-file NG003 -- legacy screen, replaced in the Q3 redesign -->
```

- `-next-line` covers the line after the comment, `-line` the comment's own line, and
  `-file` the whole file. A match counts as being on the line where it starts — for
  NG010 the `.subscribe(` line, for NG012 the `.set(`/`.update(` line.
- It only works inside a real comment (`//`, `/* */`, `<!-- -->`), never in a string.
- **The reason is required.** A directive without `-- reason` is not applied, and the
  finding says so. The reason is for whoever reviews the code.
- The block messages don't mention this syntax, so the model isn't steered toward it.
  Review new ignore comments the way you would an `eslint-disable`.

**NG010 is the likeliest rule to need one.** A root-service subscription meant to live
for the app's whole lifetime (a global event bus, a websocket manager) has no natural
point to call `takeUntilDestroyed()` against, so the "leak" NG010 flags is often
intentional there.

## Known limitations

This plugin is regex- and paren-matching, not a TypeScript compiler — it trades some
recall for being dependency-free and fast. Known false negatives:

- **NG010** cannot distinguish an RxJS `Observable.subscribe()` from a custom emitter's
  method of the same name, and its "safe" operator list (`takeUntilDestroyed`,
  `takeUntil(`, `take(`, `first(`, `firstValueFrom`, `lastValueFrom`) is matched as plain
  substrings anywhere in the preceding chain — a coincidental match (e.g. a comment-like
  string literal containing `take(`) would suppress a real finding.
- **NG004** matches across lines, so a constructor split over several lines is not the
  problem. Its real limitation is a default-value expression that contains its own parentheses *before* the injected
  parameter — e.g. `constructor(fn = () => 1, private http: HttpClient) {}` — which
  closes the rule's `[^)]*` match at the default value's `)` and leaves the injected
  parameter after it unseen (a documented, deliberate trade-off: a missed detection is
  recoverable in review, a blocked correct write is not).
- **NG012** tells a signal write from another `.set()` by argument count, so a
  one-argument `.set(x)` on a non-signal object inside an effect still fires.
- **NG016** judges `key`/`token` values by shape (known prefixes, length, entropy). A
  short or low-entropy real secret under a `key`/`token` name is missed; a long random
  non-secret identifier under one is flagged.
- **Blocking compares counts per rule**, not positions. An edit that removes one
  instance of a rule and adds another elsewhere in the same file is not blocked.
- An **unterminated `<!--` or `/*`** in a source file only disables enforcement for the
  rest of that one line — the comment stripper blanks the remainder of the line it opens
  on and resumes normal scanning from the next line, rather than swallowing everything
  after it as "inside a comment" for the whole file.
None of this is a substitute for code review. It catches the common, mechanically
detectable cases; it will not catch every way to write pre-v20 Angular.
