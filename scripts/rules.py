"""rules.py — the single source for every angular-guide rule.

Each entry carries everything said about a rule anywhere:
  id        NG0xx (blocking, pre-write), NG1xx (advisory, post-write), BG0xx (Bash)
  hook      "pre" | "post" | "bash"
  gate      None, or a key of GATES: the profile condition the rule needs
  section   grouping for the subagent rules and CLAUDE.md.template (NG rules)
  rule      one-line instruction, for subagents and CLAUDE.md.template (NG rules)
  title     headline of the hook message
  fix       the fix, in the hook message and the README table
  example   extra hook-message lines (code, rationale); optional
  skill     the skill the hook message points to (NG rules)
  catches   what the README says the rule matches

lint.py and guard.py implement the matching; this file holds the words.
tools/gen_docs.py renders the README tables and CLAUDE.md.template from it,
and subagent-rules.sh renders the subagent text at runtime.
"""

# gate -> (profile key, required value, label in docs)
GATES = {
    "v20": ("standalone_default", True, "v20+"),
    "v22": ("onpush_default", True, "v22+"),
    "zoneless": ("zoneless", True, "zoneless workspaces"),
    "vitest": ("test_runner", "vitest", "Vitest workspaces"),
    "signal_forms": ("signal_forms_available", True, "v22+"),
    "service_decorator": ("service_decorator_available", True, "v22+"),
}

SECTIONS = ["Components and templates", "Dependency injection", "Reactivity", "TypeScript",
            "Security", "Workspace-specific"]


def gate_open(gate, profile):
    if gate is None:
        return True
    key, value, _ = GATES[gate]
    return profile.get(key) == value if value is not True else profile.get(key) is True


def gate_label(gate):
    return GATES[gate][2] if gate else "—"


def message(r, title=None, extra=None):
    """The text a hook shows the model for a finding of rule r."""
    icon = "⚠️ " if r["hook"] == "post" else "🚫"
    lines = ["%s %s: %s" % (icon, r["id"], title or r["title"]), "   💡 Fix: " + r["fix"]]
    lines += ["   " + l for l in (r.get("example") or "").splitlines()]
    lines += ["   " + l for l in (extra or [])]
    if r.get("skill"):
        lines.append("   See: %s skill" % r["skill"])
    return "\n".join(lines)


RULES = [
    # ------------------------------------------------------------ Bash guard
    {
        "id": "BG001", "hook": "bash", "gate": None,
        "title": "Force push to the default branch rewrites shared history.",
        "fix": "Use `--force-with-lease`, and push to a feature branch instead.",
        "catches": "A force push (`--force`, `-f`, a combined short flag like `-fu`, or a `+ref` refspec) whose destination is `main`/`master`. The *destination* side of a `src:dst` refspec decides (so `main:feature/x` is not flagged); `refs/heads/main` counts as `main`; `HEAD`, or no refspec at all, means the checked-out branch (`git symbolic-ref --short -q HEAD`, honouring `git -C <dir>`).",
    },
    {
        "id": "BG002", "hook": "bash", "gate": None,
        "title": "`ng build --prod` — the flag was removed in Angular 12.",
        "fix": "Run `ng build`. Production is the default configuration.",
        "catches": "`ng build --prod`",
    },
    {
        "id": "BG003", "hook": "bash", "gate": None,
        "title": "`{used}` invoked but this workspace uses `{pm}` (per its lockfile).",
        "fix": "Use the manager the lockfile names — mixing package managers produces a second lockfile and divergent dependency trees.",
        "catches": "A package-manager `install`/`i`/`add`/`ci` with a manager other than the one the workspace's lockfile implies (the profile's `package_manager`).",
    },
    {
        "id": "BG004", "hook": "bash", "gate": None,
        "title": "`ng test` runs in watch mode by default and will hang this session.",
        "fix": "Run `ng test --watch=false` (Karma) or `ng test --run` (Vitest); through a package manager, pass it on: `npm test -- --watch=false`.",
        "catches": "`ng test` without a flag that prevents watch mode (`--watch=false`, `--watch false`, `--no-watch`, `--run`, or `--ci`) — and `npm test`, `npm run test`, `pnpm test` or `yarn test` when the workspace's `test` script runs `ng test` without one and none is passed through.",
    },
    {
        "id": "BG005", "hook": "bash", "gate": None,
        "title": "Deleting the lockfile discards every pinned transitive version.",
        "fix": "Delete `node_modules` alone and reinstall. Only remove the lockfile when deliberately re-resolving the whole dependency tree.",
        "catches": "`rm` with a lockfile (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `bun.lockb`) among its arguments.",
    },
    {
        "id": "BG006", "hook": "bash", "gate": None,
        "title": "`ng update --force` bypasses peer-dependency and migration checks.",
        "fix": "Resolve the reported incompatibilities, or update one package at a time. Run `ng update` without `--force` first to see what it objects to.",
        "catches": "`ng update --force`",
    },

    # ------------------------------------------------ blocking, pre-write
    {
        "id": "NG001", "hook": "pre", "gate": "v20", "section": "Components and templates",
        "rule": "Never write `standalone: true` — standalone is the default since v20.",
        "title": "`standalone: true` in a decorator.",
        "fix": "Delete the property. Standalone is the default since Angular v20 — writing it is redundant and signals a pre-v20 mental model.",
        "skill": "angular-essentials",
        "catches": "`standalone: true` in a decorator",
    },
    {
        "id": "NG002", "hook": "pre", "gate": "v20", "section": "Components and templates",
        "rule": "Never create an `@NgModule` — use standalone components.",
        "title": "`@NgModule` declaration.",
        "fix": "Use standalone components. Put shared providers in `providers` at bootstrap or on a route, and import components directly via the `imports` array.",
        "skill": "angular-essentials",
        "catches": "`@NgModule`",
    },
    {
        "id": "NG003", "hook": "pre", "gate": "v20", "section": "Components and templates",
        "rule": "Use `@if` / `@for (... ; track ...)` / `@switch`, never `*ngIf` / `*ngFor` / `*ngSwitch`.",
        "title": "Legacy structural directive (`*ngIf` / `*ngFor` / `*ngSwitch`).",
        "fix": "Use native control flow — `@if (cond) { }`, `@for (x of xs; track x.id) { }`, `@switch (v) { @case (a) { } }`. It needs no imports, is faster, and is the only supported form going forward.",
        "skill": "angular-essentials",
        "catches": "`*ngIf` / `*ngFor` / `*ngSwitch` / `[ngSwitch]`",
    },
    {
        "id": "NG004", "hook": "pre", "gate": "v20", "section": "Dependency injection",
        "rule": "Use `inject()` at field level, never constructor-parameter injection.",
        "title": "Constructor-parameter dependency injection.",
        "fix": "Use the `inject()` function at field level: `private readonly http = inject(HttpClient);`",
        "example": "It gives better type inference, works in field initializers and functional guards/interceptors, and avoids inheritance boilerplate.",
        "skill": "angular-essentials",
        "catches": "Constructor-parameter DI (`constructor(private x: T)`) — **only inside a file that already carries an Angular class decorator** (`@Component`, `@Directive`, `@Injectable`, `@Service`, `@Pipe`, or `@NgModule`); a plain value class like `Money` with a `constructor(private amount: number)` is not flagged.",
    },
    {
        "id": "NG005", "hook": "pre", "gate": "v20", "section": "Components and templates",
        "rule": "Use `input()` / `output()` / `model()`, never the `@Input()` / `@Output()` decorators.",
        "title": "`@Input()` / `@Output()` decorator.",
        "fix": "Use the signal-based functions — `input()` / `input.required()`, `output()`, `model()`:",
        "example": "  readonly name = input.required<string>();\n  readonly saved = output<Item>();\n  readonly value = model<string>(\"\");\nSignal inputs are readable in computed() without a lifecycle hook.",
        "skill": "angular-essentials",
        "catches": "`@Input()` / `@Output()` decorators",
    },
    {
        "id": "NG006", "hook": "pre", "gate": "v22", "section": "Components and templates",
        "rule": "Never set `changeDetection: ChangeDetectionStrategy.OnPush` — it is the default in v22.",
        "title": "Explicit `changeDetection: ChangeDetectionStrategy.OnPush`.",
        "fix": "Delete the property and its import. OnPush is the default strategy in Angular v22 — setting it explicitly is now noise.",
        "skill": "performance-and-zoneless",
        "catches": "Explicit `changeDetection: ChangeDetectionStrategy.OnPush`",
    },
    {
        "id": "NG007", "hook": "pre", "gate": None, "section": "TypeScript",
        "rule": "Never use `any` — use `unknown` and narrow it.",
        "title": "`any` type detected.",
        "fix": "Use `unknown` when the type is genuinely uncertain and narrow it, or give the value its real type. `any` disables every check TypeScript exists to provide.",
        "skill": "angular-essentials",
        "catches": "`any` in a `.ts` file (as a type annotation, `as any`, or `<any>`), not the word inside a string",
    },
    {
        "id": "NG008", "hook": "pre", "gate": None, "section": "Components and templates",
        "rule": "Use `[class.x]` / `[style.x]` bindings, never `ngClass` / `ngStyle`.",
        "title": "`ngClass` / `ngStyle`.",
        "fix": "Use native bindings — `[class.active]=\"isActive()\"`, `[style.width.px]=\"w()\"`, or `[class]=\"classRecord()\"`. They need no import and avoid an extra directive instance per element.",
        "skill": "angular-essentials",
        "catches": "`[ngClass]` / `[ngStyle]` (attribute or property-binding form)",
    },
    {
        "id": "NG009", "hook": "pre", "gate": None, "section": "Components and templates",
        "rule": "Use the `host` object in decorator metadata, never `@HostBinding` / `@HostListener`.",
        "title": "`@HostBinding` / `@HostListener` decorator.",
        "fix": "Use the `host` object in the decorator metadata: `@Component({ host: { \"[class.active]\": \"isActive()\", \"(click)\": \"onClick($event)\" } })`",
        "example": "It keeps host behaviour in one place and is statically analysable.",
        "skill": "angular-essentials",
        "catches": "`@HostBinding` / `@HostListener` decorators",
    },
    {
        "id": "NG010", "hook": "pre", "gate": None, "section": "Reactivity",
        "rule": "Never call `.subscribe()` without teardown in the chain — prefer the `async` pipe, `toSignal()`, or `httpResource()`; for a one-shot HTTP command, `await firstValueFrom(...)`.",
        "title": "`.subscribe()` with no teardown in its chain.",
        "fix": "Prefer not subscribing at all — use the `async` pipe, `toSignal(obs$)`, or `httpResource()`. For a one-shot HTTP command, `await firstValueFrom(...)`. When you must subscribe, add teardown: `obs$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe(...)`",
        "example": "Manual subscriptions without teardown are the most common memory leak in Angular apps.",
        "skill": "rxjs-interop",
        "catches": "`.subscribe()` whose call chain (walked back at bracket depth 0 to the previous `;`, `,`, `=>`, or unmatched opener, so arrow functions inside earlier operators don't cut it short) contains none of `takeUntilDestroyed`, `takeUntil(`, `take(`, `first(`, `firstValueFrom`, `lastValueFrom` — matched as plain substrings, and skipped entirely in `.spec.ts`/`.test.ts` files.",
    },
    {
        "id": "NG011", "hook": "pre", "gate": None, "section": "Reactivity",
        "rule": "Signals have no `.mutate()` — use `.set()` or `.update()`.",
        "title": "`.mutate()` on a signal — the API was removed.",
        "fix": "Use `set()` with a new value, or `update()` with a pure transform: `this.items.update((xs) => [...xs, item]);`",
        "example": "Signals compare by reference, so in-place mutation would not notify readers.",
        "skill": "signals-essentials",
        "catches": "`.mutate(` on a signal",
    },
    {
        "id": "NG012", "hook": "pre", "gate": None, "section": "Reactivity",
        "rule": "Never write a signal from inside `effect()` — derived state is `computed()`; writable state derived from other signals is `linkedSignal()`.",
        "title": "`effect()` writes a signal.",
        "fix": "Derived state belongs in `computed()`; writable state derived from other signals belongs in `linkedSignal()`. Effects are for side effects that leave the reactive graph — logging, third-party DOM, analytics.",
        "example": "Writing signals inside an effect creates feedback loops and re-entrant change detection. Restructure first; only if the write cannot be expressed as `computed()` or `linkedSignal()` (e.g. resetting unrelated state in response to an event-like signal), isolate it in `untracked()` with a comment saying why.",
        "skill": "signals-essentials",
        "catches": "`effect(...)` whose body (balanced-paren extracted, so it correctly spans nested calls) contains a one-argument `.set(` or `.update(` outside an `untracked(...)` callback — a two-argument `.set(k, v)` is a `Map`/`HttpParams`/`URLSearchParams`, not a signal",
    },
    {
        "id": "NG013", "hook": "pre", "gate": "v20", "section": "Components and templates",
        "rule": "Every `@for` needs a `track` expression.",
        "title": "`@for` without a `track` expression.",
        "fix": "Add a stable identity — `@for (item of items(); track item.id) { }`. `track` is mandatory; without it Angular cannot reuse DOM nodes and rebuilds the whole list on every change.",
        "skill": "performance-and-zoneless",
        "catches": "`@for (...)` whose balanced-paren clause contains no `track` — the clause is extracted by counting parens, not by matching to the first `)`, so `@for (x of items(); track x.id)` is correctly **not** flagged despite the inner `items()` call.",
    },
    {
        "id": "NG014", "hook": "pre", "gate": None, "section": "Security",
        "rule": "Never bind `[innerHTML]` / `[outerHTML]`.",
        "title": "`[innerHTML]` binding.",
        "fix": "Render text with interpolation, or compose real components. If you must render untrusted markup, sanitize it server-side and render through a vetted component — Angular sanitizes `[innerHTML]` but the pattern still invites XSS as soon as someone reaches for `bypassSecurityTrust*`.",
        "skill": "angular-essentials",
        "catches": "`[innerHTML]` / `[outerHTML]` bindings",
    },
    {
        "id": "NG015", "hook": "pre", "gate": None, "section": "Security",
        "rule": "Never call `bypassSecurityTrust*`.",
        "title": "`bypassSecurityTrust*` call.",
        "fix": "This disables Angular XSS protection for that value. Sanitize upstream and render normally. If a genuine trusted-value case exists, it belongs in one reviewed, narrowly-scoped helper — never inline in a component.",
        "skill": "angular-essentials",
        "catches": "Any `bypassSecurityTrust*` call",
    },
    {
        "id": "NG016", "hook": "pre", "gate": None, "section": "Security",
        "rule": "Never put a secret in `environment*.ts` — it ships to the browser.",
        "title": "Secret-shaped value in an environment file.",
        "fix": "`environment.ts` is compiled into the browser bundle — anything in it is public. Move the secret behind your backend and have the client call your API. Build-time injection does not help; the value still ships.",
        "skill": "angular-essentials",
        "catches": "In a file under an `environments?/` directory or named `environment*.ts`, a string literal assigned to a key whose last word is `password`/`secret`/`credential` (any non-empty value), or `key`/`token` (only a value that looks issued: a known secret prefix like `sk_live_`/`ghp_`/`AKIA`, or 20+ high-entropy characters). URLs, lines that read `process.env`/`import.meta.env`, and browser keys that are public by design (`AIza…`, Stripe `pk_…`) are skipped — so `storageKey: \"app-theme\"` passes.",
    },
    {
        "id": "NG017", "hook": "pre", "gate": "zoneless", "section": "Workspace-specific",
        "rule": "Never import `zone.js` in a zoneless workspace — it re-introduces the monkey-patching zoneless exists to remove.",
        "title": "`zone.js` import in a zoneless workspace.",
        "fix": "Remove the import. This app runs with `provideZonelessChangeDetection()`; loading zone.js re-introduces monkey-patching of every async API and negates the benefit.",
        "skill": "performance-and-zoneless",
        "catches": "An `import`/`require` of `zone.js`",
    },
    {
        "id": "NG018", "hook": "pre", "gate": "vitest", "section": "Workspace-specific",
        "rule": "Never use Jasmine APIs (`jasmine.*`) in a Vitest workspace — use `vi.fn()` / `vi.spyOn()`; TestBed itself is unchanged.",
        "title": "Jasmine API in a Vitest workspace.",
        "fix": "Use the Vitest equivalents — `vi.fn()` for `jasmine.createSpy()`, `vi.spyOn()` for `spyOn()`, `expect.objectContaining()` for `jasmine.objectContaining()`. TestBed itself is unchanged.",
        "skill": "testing-essentials",
        "catches": "A `jasmine.*` reference in a `.ts` file",
    },

    # ----------------------------------------------- advisory, post-write
    {
        "id": "NG101", "hook": "post", "gate": None, "section": "Advisory",
        "rule": "Route `component:` references should be lazy (`loadComponent`).",
        "title": "Route declared with an eager `component:` reference.",
        "fix": "Lazy-load it so the feature leaves the initial bundle: `{ path: \"admin\", loadComponent: () => import(\"./admin/admin-page\").then((m) => m.AdminPage) }`",
        "example": "Eager routes are defensible for a small shell route — for a feature screen they are almost always a mistake.",
        "skill": "performance-and-zoneless",
        "catches": "A route object in a file whose path matches `routes?.ts`/`.routes.ts`/contains `routing`, with an eager `component: SomeComponent` reference",
    },
    {
        "id": "NG102", "hook": "post", "gate": "signal_forms", "section": "Advisory",
        "rule": "New forms should use Signal Forms, not `FormBuilder`/`FormGroup`.",
        "title": "Reactive Forms in a workspace where Signal Forms are stable.",
        "fix": "Prefer Signal Forms for new forms — form state is signals, so it composes with `computed()` and needs no `valueChanges` subscription. Staying on Reactive Forms is correct when extending an existing Reactive Forms screen; starting a new one there is not.",
        "skill": "angular-essentials",
        "catches": "`FormBuilder` / `new FormGroup` / `fb.group(` in a non-spec `.ts` file",
    },
    {
        "id": "NG103", "hook": "post", "gate": "service_decorator", "section": "Advisory",
        "rule": "`@Injectable({ providedIn: 'root' })` should be `@Service()`.",
        "title": "`@Injectable({ providedIn: \"root\" })`.",
        "fix": "Use the `@Service()` decorator — it is the same root-provided singleton with less ceremony.",
        "skill": "state-management",
        "catches": "`@Injectable({ providedIn: 'root' })`, including when the object spans several lines",
    },
    {
        "id": "NG104", "hook": "post", "gate": None, "section": "Advisory",
        "rule": "A static `<img src>` should use `NgOptimizedImage` / `ngSrc`.",
        "title": "Static `<img src>` without NgOptimizedImage.",
        "fix": "Import `NgOptimizedImage` and use `ngSrc` with explicit `width`/`height` (or `fill`): `<img ngSrc=\"/assets/hero.png\" width=\"800\" height=\"600\" alt=\"Hero\">`",
        "example": "It adds lazy loading, srcset generation, and priority hints, and it prevents layout shift.",
        "skill": "performance-and-zoneless",
        "catches": "A static `<img ... src=\"...\">` with no `NgOptimizedImage`, including a tag Prettier has wrapped across lines.",
    },
    {
        "id": "NG105", "hook": "post", "gate": None, "section": "Advisory",
        "rule": "No direct `document`/`window` in a component — inject `DOCUMENT`, use `viewChild()` / `afterRenderEffect()`.",
        "title": "Direct `document` / `window` access in a component.",
        "fix": "Use `viewChild()` signal queries for element access, `afterRenderEffect()` for DOM work that must run post-render, and inject `DOCUMENT` rather than reaching for the global. Direct globals break SSR, where neither exists.",
        "skill": "component-architecture",
        "catches": "Direct `document.`/`window.` access (the globals — `this.document` from `inject(DOCUMENT)` is not flagged) in a file that is a component — the path ends `.component.ts`, **or** its (comment-stripped) content contains `@Component` — skipped entirely in `.spec.ts`/`.test.ts` files.",
    },
    {
        "id": "NG106", "hook": "post", "gate": None, "section": "Advisory",
        "rule": "Keep components small and HTTP-free — past ~200 lines or ~8 inputs, split; HTTP belongs in a service.",
        "title": "Component complexity.",
        "fix": "Move HTTP into a service; split the component; collapse many scalar inputs into one object input.",
        "skill": "component-architecture",
        "catches": "Structural complexity in a component file (same `.component.ts`-or-`@Component` test as NG105; also runnable standalone as `analyze_quality.sh`): an `HttpClient` reference, more than ~200 non-blank lines, or more than ~8 `input()`/`input.required()` declarations — skipped entirely in `.spec.ts`/`.test.ts` files.",
    },
]

BY_ID = {r["id"]: r for r in RULES}
