---
name: signals-essentials
description: MANDATORY for ALL Angular signal and reactivity work. Invoke before writing signal, computed, linkedSignal, effect, or resource.
paths:
  - "**/*.ts"
---

# Signals Essentials

Angular documents each signal primitive on its own page. It does not tell you which one
to reach for. Picking the wrong one — almost always an `effect()` where `computed()`
belongs — is the single most common failure mode when an AI writes modern Angular. This
skill is the decision procedure Angular's own docs deliberately don't give you.

## RULES — Follow these with no exceptions

1. **Derived state is `computed()`** — never an `effect()` that writes a signal (NG012)
2. **State derived from other signals but independently writable is `linkedSignal()`**
3. **`effect()` is only for leaving the reactive graph** — logging, third-party DOM, analytics
4. **Never call `.mutate()`** — signals compare by reference; use `set()` or `update()` (NG011)
5. **`update()` takes a pure transform** — return a new value, never mutate the argument
6. **Read signals in templates by calling them** — `count()`, not `count`
7. **Use `untracked()`** when reading a signal inside a reactive context without depending on it
8. **Async state is `resource()` / `rxResource()` / `httpResource()`** (v22+; before v22, `HttpClient` + `toSignal()`), not an effect plus a signal

## The decision table

Every signal question reduces to one of these five rows. Find the row that matches what
you need, and the primitive is decided — no judgment call left to get wrong.

| Need | Primitive |
|---|---|
| Independent writable state | `signal()` |
| Value derived purely from other signals | `computed()` |
| Derived, but locally overridable and reset when its source changes | `linkedSignal()` |
| Async data keyed on other signals | `resource()` / `httpResource()` * |
| A side effect outside the reactive graph | `effect()` |

\* Stable in v22+. Before v22, use `HttpClient` + `toSignal()` for the same shape.

If what you're about to write doesn't fit any row cleanly, that's a signal the design
needs rethinking before the code — not a reason to reach for `effect()` as a catch-all.

## 1. Derived state is `computed()`, never `effect()` (NG012)

This is the dominant mistake: using `effect()` to push a derived value into a second
signal, rather than deriving it directly. It matters for a concrete reason — `effect()`
runs *after* change detection settles, as a reaction, so the derived signal is stale for
one extra frame every time an input changes. `computed()` has no such lag: it recomputes
lazily, exactly when read, and Angular's reactive graph tracks the dependency
automatically. The effect version is also re-entrant risk — writing a signal from inside
an effect can trigger the same effect again if it also reads that signal.

Bad:

```typescript
export class CartTotal {
  readonly items = signal<CartItem[]>([]);
  readonly total = signal(0);

  constructor() {
    // Runs one frame after items() changes. total() is stale in between,
    // and if anything else reads/writes total() inside its own effect,
    // this can re-enter.
    effect(() => {
      const sum = this.items().reduce((acc, i) => acc + i.price * i.qty, 0);
      this.total.set(sum);
    });
  }
}
```

Good:

```typescript
export class CartTotal {
  readonly items = signal<CartItem[]>([]);
  readonly total = computed(() =>
    this.items().reduce((acc, i) => acc + i.price * i.qty, 0),
  );
}
```

`total()` is never out of sync with `items()` — there is no second frame in which one has
updated and the other hasn't, and there is no way to write `total` from anywhere else by
mistake.

## 2. `linkedSignal()` for writable-but-derived state

Some state starts from another signal's value but the user can override it locally, and
that override should reset when the source changes. `computed()` can't do this — it's
read-only. A plain `signal()` plus a manual sync `effect()` can, but reintroduces the same
staleness problem as rule 1. `linkedSignal()` is built for exactly this shape:

```typescript
export class ShippingForm {
  readonly countries = input.required<Country[]>();

  // Defaults to the first country, but the user can pick a different one —
  // and if `countries()` changes (a new order, a new address), it resets.
  readonly selectedCountry = linkedSignal(() => this.countries()[0]);
}
```

## 3. `effect()` is only for leaving the reactive graph

An effect's job is to do something signals can't: call a third-party library, write to
`localStorage`, send an analytics event, log. If the body's only purpose is to compute a
value that lives in another signal, it belongs in rule 1 instead.

```typescript
export class SessionTracker {
  readonly userId = input.required<string>();
  private readonly analytics = inject(AnalyticsService);

  constructor() {
    effect(() => {
      // Leaves the reactive graph: this is I/O, not derived state.
      this.analytics.identify(this.userId());
    });
  }
}
```

## 4. Never call `.mutate()` (NG011)

`.mutate()` was removed from the signal API. Signals notify readers by comparing the
*reference* of the new value to the old one — mutating an array or object in place leaves
the reference unchanged, so nothing re-renders even where `.mutate()` still appears in
old code samples.

Bad:

```typescript
this.items.mutate((xs) => xs.push(newItem));
```

Good:

```typescript
this.items.update((xs) => [...xs, newItem]);
```

## 5. `update()` takes a pure transform

The callback passed to `update()` must return a new value, not mutate its argument and
return nothing. Angular passes the current value in; what you return becomes the new
value and is compared by reference against the old one to decide whether to notify.

Bad:

```typescript
this.items.update((xs) => {
  xs.push(newItem); // mutates in place, returns the array's own push() result (a number!)
});
```

Good:

```typescript
this.items.update((xs) => [...xs, newItem]);
```

## 6. Read signals in templates by calling them

A signal is a function. `{{ count }}` interpolates the function reference (Angular's
template type-checker will flag this in strict mode, but it's easy to miss without it);
`{{ count() }}` reads the current value and subscribes the template to future changes.

Bad:

```html
<p>Count: {{ count }}</p>
```

Good:

```html
<p>Count: {{ count() }}</p>
```

## 7. `untracked()` to read without depending

Sometimes a reactive context needs a signal's current value without becoming dependent on
it — most often inside an `effect()` that should not re-run just because an incidental
signal changed.

```typescript
private readonly analytics = inject(AnalyticsService);

constructor() {
  effect(() => {
    const id = this.itemId(); // dependency: effect re-runs when this changes
    // sessionId() is read but must not itself trigger a re-run:
    const session = untracked(() => this.sessionId());
    this.analytics.track('view', { id, session });
  });
}
```

## 8. Async state is `resource()` / `rxResource()` / `httpResource()` (v22+, stable)

Don't hand-roll async state with a signal for the data, a signal for loading, a signal
for the error, and an `effect()` that populates all three — that's rule 1's mistake
applied to network calls. The resource family does this natively and exposes
`.value()`, `.isLoading()`, `.error()`, and `.status()` as signals.

Bad:

```typescript
export class UserLookup {
  readonly userId = input.required<string>();
  readonly user = signal<User | null>(null);
  readonly loading = signal(false);

  constructor(userService = inject(UserService)) {
    effect(() => {
      this.loading.set(true);
      userService.fetch(this.userId()).then((u) => {
        this.user.set(u);
        this.loading.set(false);
      });
    });
  }
}
```

Good:

```typescript
export class UserLookup {
  readonly userId = input.required<string>();
  private readonly userService = inject(UserService);

  readonly userResource = resource({
    params: () => this.userId(),
    loader: ({ params }) => this.userService.fetch(params),
  });
}
```

The template reads `userResource.value()`, `userResource.isLoading()`, and
`userResource.error()` directly — no manual state juggling, and it automatically
re-fetches when `userId()` changes.

Before v22, without `resource()`, the closest equivalent is `toObservable()` piped
through `switchMap()` and converted back with `toSignal()` — see `rxjs-interop` rule 3
for the boundary-conversion pattern this relies on:

```typescript
export class UserLookup {
  readonly userId = input.required<string>();
  private readonly userService = inject(UserService);

  readonly user = toSignal(
    toObservable(this.userId).pipe(switchMap((id) => this.userService.fetch(id))),
    { initialValue: null as User | null },
  );
}
```

It loses `.isLoading()` and `.error()` as separate signals — that gap is exactly what
`resource()` closes once v22 is available.

## Reference

This skill covers judgment — which primitive, and why — not API surface. For method
signatures, options objects, and migration detail, the authority is Angular's own
materials:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`
