---
name: rxjs-interop
description: MANDATORY for ALL RxJS work in an Angular workspace. Invoke before writing subscribe, toSignal, toObservable, or any Observable pipeline.
file_patterns:
  - "**/*.ts"
auto_suggest: true
---

# RxJS Interop

Signals did not make RxJS obsolete. They made it optional for the cases RxJS was never
the best tool for — most component and template state. Angular's docs cover the interop
functions in isolation; they don't tell you when to reach for `subscribe()` at all versus
converting reflexively to signals. That judgment call is this skill.

## RULES — Follow these with no exceptions

1. **Prefer not subscribing** — use the `async` pipe, `toSignal()`, or `httpResource()` (v22+)
2. **Every manual `.subscribe()` needs teardown** — `takeUntilDestroyed()` (NG010)
3. **`toSignal()` at the boundary** — convert to signals as early as possible
4. **`toObservable()` only when a real RxJS operator is needed** — debounce, retry, concurrency
5. **Never nest subscribes** — use `switchMap` / `concatMap` / `mergeMap`
6. **`switchMap` for cancel-previous** (typeahead), **`concatMap` for ordered**, **`mergeMap` for parallel**
7. **Never `subscribe()` inside a `computed()` or `effect()`**

## 1. Prefer not subscribing

A manual `subscribe()` call is a manual teardown obligation and a manual re-entrancy risk.
Most of the time there's a construct that avoids both:

- Template-only consumption → `| async`
- Feed a signal-based component or `computed()` → `toSignal()`
- An HTTP call → `httpResource()` (v22+, skip RxJS entirely); before v22, `toSignal(this.http.get(...))` — see rule 3

```typescript
export class SearchResults {
  private readonly search = inject(SearchService);
  readonly term = input.required<string>();

  readonly results = toSignal(
    toObservable(this.term).pipe(
      debounceTime(300),
      switchMap((term) => this.search.query(term)),
    ),
    { initialValue: [] as Item[] },
  );
}
```

## 2. Every manual `.subscribe()` needs teardown (NG010)

When a genuine subscription is unavoidable — most often to trigger a side effect rather
than to read a value — it must terminate itself. Without teardown, the subscription
outlives the component and is the most common memory leak in Angular apps.

Bad:

```typescript
export class AuditLog {
  private readonly events = inject(EventBus);

  constructor() {
    this.events.stream$.subscribe((e) => this.record(e));
  }

  private record(e: AppEvent) {}
}
```

Good:

```typescript
export class AuditLog {
  private readonly events = inject(EventBus);
  private readonly destroyRef = inject(DestroyRef);

  constructor() {
    this.events.stream$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe((e) => this.record(e));
  }

  private record(e: AppEvent) {}
}
```

`take(1)`, `first()`, `takeUntil(...)`, `firstValueFrom(...)`, and `lastValueFrom(...)`
are equally valid teardown strategies when the chain is naturally self-terminating —
`takeUntilDestroyed()` is the default choice, not the only one.

## 3. `toSignal()` at the boundary

Convert an Observable to a signal as early as it enters signal-consuming code, rather
than threading the Observable deep into a component tree and converting late. The
earlier the conversion, the more of the app gets to compose with `computed()` instead of
RxJS operators.

```typescript
@Service()
export class UserStore {
  private readonly http = inject(HttpClient);

  readonly currentUser = toSignal(this.http.get<User>('/api/me'), {
    initialValue: null,
  });
}
```

## 4. `toObservable()` only when a real operator is needed

Going the other direction — signal to Observable — is justified when you need an
operator signals don't have: `debounceTime`, `retry` with backoff, `race`, and similar.
Converting a signal to an Observable just to convert it straight back is wasted
indirection.

```typescript
export class TypeaheadBox {
  readonly query = signal('');

  readonly suggestions = toSignal(
    toObservable(this.query).pipe(
      debounceTime(200),
      distinctUntilChanged(),
      switchMap((q) => this.lookup(q)),
    ),
    { initialValue: [] as string[] },
  );

  private lookup(q: string) {
    return of([] as string[]);
  }
}
```

## 5. Never nest subscribes

A `subscribe()` inside another `subscribe()` loses cancellation, loses error
propagation, and is nearly always better expressed as a flattening operator.

Bad:

```typescript
this.auth.currentUser$.subscribe((user) => {
  this.orders.forUser(user.id).subscribe((orders) => {
    this.orders$.next(orders);
  });
});
```

Good:

```typescript
readonly userOrders = toSignal(
  this.auth.currentUser$.pipe(
    switchMap((user) => this.orders.forUser(user.id)),
  ),
  { initialValue: [] as Order[] },
);
```

## 6. Choosing the flattening operator

| Operator | Behavior | Typical use |
|---|---|---|
| `switchMap` | Cancels the previous inner stream | Typeahead, "latest wins" |
| `concatMap` | Queues inner streams, runs in order | Sequential writes that must not interleave |
| `mergeMap` | Runs inner streams concurrently | Independent parallel requests |

Picking the wrong one is a correctness bug, not a style choice — `switchMap` on a save
request can cancel a write mid-flight; `mergeMap` on a typeahead lets stale results race
the current one back to the UI.

## 7. Never `subscribe()` inside `computed()` or `effect()`

`computed()` must be pure and synchronous — a `subscribe()` inside it has no way to push
a later emission back into the computation. An `effect()` can technically call
`subscribe()`, but then owns a subscription with a lifetime disconnected from the
effect's own re-run cycle, which reintroduces the teardown problem from rule 2. Convert
the Observable to a signal first (rule 3), then read the signal from `computed()` /
`effect()` like any other.

## When RxJS is still the right tool

The instinct to convert every stream to a signal produces worse code for genuinely
stream-shaped problems. RxJS keeps winning at:

- **Time-based coordination** — `debounceTime`, `throttleTime`, `auditTime`. Signals have
  no concept of time between emissions; a `computed()` re-runs the instant a dependency
  changes.
- **Retry with backoff** — `retry({ count, delay })`, `retryWhen`. There's no signal
  equivalent for "try again, waiting longer each time."
- **Racing multiple sources** — `race`, `merge` with `takeUntil`. Coordinating "whichever
  of these resolves first" across independent async sources is what RxJS operators are
  for.
- **Complex multi-source coordination** — `combineLatest`, `withLatestFrom`,
  `bufferWhen`. When several independent streams must be combined with real operator
  semantics rather than simple "all are signals, read them all in one `computed()`."

If the problem is genuinely about *when* things happen relative to each other, keep it in
RxJS and convert to a signal only at the point the result needs to reach a component.

## Reference

For operator reference and interop function signatures, the authority is Angular's own
materials:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`
- RxJS operator decision tree: `rxjs.dev`
