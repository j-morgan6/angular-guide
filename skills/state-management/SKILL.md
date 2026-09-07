---
name: state-management
description: MANDATORY before introducing shared state or a state library. Invoke before adding a store, a state service, or NgRx.
file_patterns:
  - "**/*.store.ts"
  - "**/*.service.ts"
  - "**/*.ts"
auto_suggest: true
---

# State Management

Angular ships no guidance here at all — no opinion on when state should leave a
component, no recommended store shape, nothing. That silence is exactly why a model
defaults to whatever its training data over-represents, which is usually "reach for NgRx"
regardless of whether the app has state complex enough to justify it. This skill is the
escalation ladder Angular doesn't provide.

## RULES — Follow these with no exceptions

1. **Start with a `signal()` in the component** — most state never needs to leave it
2. **Escalate to a root-provided service with signals** only when two components need the same state
3. **Escalate to a SignalStore** only when you need entities, effects, and devtools together
4. **Never reach for NgRx by default** — it is the answer to a problem most apps do not have
5. **Expose state as readonly** — `readonly items = this._items.asReadonly()`
6. **Mutations go through named methods**, never by writing the signal from outside
7. **On v22+, use `@Service`** rather than `@Injectable({ providedIn: "root" })` (NG103)
8. **Derived state is `computed()` in the store**, never recomputed in each consumer

## The escalation ladder

Climb one rung at a time, and only when the rung below genuinely can't do the job. Each
rung has a real cost — paid in indirection, boilerplate, or both — so going up a rung you
didn't need is not a neutral choice.

### Rung 0 — `signal()` in the component

```typescript
@Component({ selector: 'app-filter-panel' })
export class FilterPanelComponent {
  readonly query = signal('');
  readonly onlyInStock = signal(false);
}
```

**Cost:** none. **You have gone far enough when:** no other component needs to read or
write this state. If the answer to "does a sibling or a parent need this too" is no, stop
here — this is where almost all component state belongs, and it needs no test setup
beyond the component itself.

### Rung 1 — a root-provided service with signals

`@Service()` below is v22+ (rule 7); on v20–v21 the identical store is `@Injectable({ providedIn: 'root' })`.

```typescript
@Service()
export class CartStore {
  private readonly _items = signal<CartItem[]>([]);
  readonly items = this._items.asReadonly();
  readonly total = computed(() =>
    this._items().reduce((sum, i) => sum + i.price * i.qty, 0),
  );

  addItem(item: CartItem) {
    this._items.update((xs) => [...xs, item]);
  }

  removeItem(id: string) {
    this._items.update((xs) => xs.filter((i) => i.id !== id));
  }
}
```

**Cost:** a new injectable with its own test file; every consumer now has an implicit
dependency on shared state instead of owning its own. **You have gone far enough when:**
you need entity collections with normalized lookups, orchestrated side effects, or a
devtools timeline — none of which a plain service naturally gives you. If you just need
two or three components to read and write the same handful of signals, this rung is the
answer and the ladder stops here.

### Rung 2 — SignalStore

A SignalStore (from `@ngrx/signals`) is justified when you need entities, effects, and
devtools *together* — not when you need any one of them alone. It packages
`withEntities()`, `withMethods()`, `rxMethod()`-based effect orchestration, and Redux
DevTools integration in one place.

**Cost:** a new dependency, a new API surface (`patchState`, `withComputed`,
`withMethods`) your whole team now needs to know, and a devtools integration to keep
wired up. **You have gone far enough when:** you're not reaching for entity helpers or
effect orchestration — if a plain signal-based service (rung 1) covers what you actually
need, adopting SignalStore bought you a library dependency and nothing else.

### Rung 3 — full NgRx (actions, reducers, effects, store)

**Never the default.** Full NgRx is the answer to a problem most apps do not have:
multiple independent teams that need to reason about state changes as an audited,
replayable event log, with strict unidirectional data flow enforced across a large
surface area. **Cost:** the largest on this ladder — action creators, reducers, effect
classes, selectors, and a mental model (dispatch → reduce → select) layered on top of
everything rungs 0–2 already do more simply. **You have gone far enough** at rung 2 for
the overwhelming majority of applications; reach for rung 3 only when the event-log audit
trail and strict action-based flow are themselves the requirement, not merely "the state
got a bit complicated."

## 5. Expose state as readonly

A store's signals should be internally mutable and externally read-only. Consumers read
`items()`; they call `addItem(...)` to change it. This is what makes rule 6 possible to
enforce by construction rather than by convention.

```typescript
private readonly _items = signal<CartItem[]>([]);
readonly items = this._items.asReadonly();
```

## 6. Mutations go through named methods

Bad:

```typescript
@Service()
export class CartStore {
  readonly items = signal<CartItem[]>([]);
}

// elsewhere, anywhere in the app:
cartStore.items.update((xs) => [...xs, item]);
```

Any consumer can mutate `items` from anywhere, with no single place to find every way the
cart changes.

Good:

```typescript
@Service()
export class CartStore {
  private readonly _items = signal<CartItem[]>([]);
  readonly items = this._items.asReadonly();

  addItem(item: CartItem) {
    this._items.update((xs) => [...xs, item]);
  }
}
```

Now `addItem` is the one place to add validation, logging, or a side effect when items
change — and grepping for `_items.update` finds every mutation in the codebase.

## 7. `@Service`, not `@Injectable({ providedIn: 'root' })` (v22+, NG103)

On v22+, `@Service()` is a root-provided singleton with less ceremony. It's still correct
to use `@Injectable({ providedIn: 'root' })` on an older target, or on a service that
takes constructor-injection options `@Injectable` supports and `@Service` doesn't — but
for a new store on v22+, prefer `@Service()`.

## 8. Derived state is `computed()` in the store

Compute once, in the store, and export the result — not the same reduction copy-pasted
into a `computed()` in every consuming component.

Bad:

```typescript
// component A
readonly total = computed(() =>
  this.cartStore.items().reduce((sum, i) => sum + i.price * i.qty, 0),
);

// component B — same computation, duplicated
readonly cartValue = computed(() =>
  this.cartStore.items().reduce((sum, i) => sum + i.price * i.qty, 0),
);
```

Good:

```typescript
@Service()
export class CartStore {
  private readonly _items = signal<CartItem[]>([]);
  readonly items = this._items.asReadonly();
  readonly total = computed(() =>
    this._items().reduce((sum, i) => sum + i.price * i.qty, 0),
  );
}
```

Every consumer reads `cartStore.total()` — one definition, one place to change the
calculation.

## Reference

For store implementation detail — `@ngrx/signals` API, effect orchestration, DevTools
setup — the authority is each library's own documentation. This skill covers only when to
escalate, not the API of what you escalate to:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`
- `@ngrx/signals` documentation, for SignalStore API detail
