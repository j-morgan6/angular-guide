---
name: data-loading
description: MANDATORY for ALL HTTP and async data work in an Angular workspace. Invoke before writing HttpClient calls, interceptors, resource, or httpResource.
paths:
  - "**/*.service.ts"
  - "**/*.ts"
---

# Data Loading

Angular's docs explain `HttpClient`, interceptors, and the resource family each in
isolation. They don't tell you which one a given request should use, or that reaching
for `HttpClient` inside a component is the default an AI falls back to under time
pressure. This skill is that decision, made once.

## RULES — Follow these with no exceptions

1. **`httpResource()` for reads keyed on signals** (v22+) — it tracks, cancels, and exposes loading and error state
2. **`HttpClient` directly only for commands** — POST/PUT/DELETE, or one-shot calls
3. **Never fetch in a component** (NG106)
4. **Independent requests run in parallel** — never `await` them in sequence
5. **Interceptors are functions**, registered via `withInterceptors([...])`
6. **Handle errors at the boundary** — an interceptor for cross-cutting concerns, `.error()` for per-view state
7. **Never subscribe to an HTTP call without teardown** (NG010)
8. **`resource()` for non-HTTP async**, `rxResource()` when the source is an Observable (both v22+)

## Choosing the right tool

| Need | Use |
|---|---|
| Read, keyed on one or more signals (route param, filter, page) | `httpResource()` (v22+) |
| Read, before v22 | `HttpClient` + `toSignal()` |
| Write — POST / PUT / PATCH / DELETE, or any one-shot call | `HttpClient` directly |
| Non-HTTP async source (file read, IndexedDB, a promise-returning SDK) | `resource()` (v22+) |
| Async source that is already an Observable you don't control | `rxResource()` (v22+) |

`httpResource()`, `resource()`, and `rxResource()` are stable as of Angular v22. Before
v22, use `HttpClient` and convert with `toSignal()` — see `signals-essentials` rule 8 and
`rxjs-interop` rule 3 for that boundary-conversion pattern. `rxResource()`'s early
subscription-leak (the source Observable stayed subscribed after the resource's request
signal changed) was fixed in v22 — don't carry over workarounds for it from pre-v22 code.

## 1. `httpResource()` for signal-keyed reads

```typescript
@Service() // v22+
export class UserService {
  userResource(userId: () => string) {
    return httpResource<User>(() => `/api/users/${userId()}`); // v22+
  }
}
```

The resource re-fetches whenever `userId()` changes, cancels the in-flight request if a
new one supersedes it, and exposes `.value()`, `.isLoading()`, and `.error()` as signals
— no manually-synchronized loading/error state. Before v22, the same shape is:

```typescript
@Injectable({ providedIn: 'root' })
export class UserService {
  private readonly http = inject(HttpClient);

  user(userId: () => string) {
    return toSignal(
      toObservable(userId).pipe(switchMap((id) => this.http.get<User>(`/api/users/${id}`))),
      { initialValue: null as User | null },
    );
  }
}
```

## 2. `HttpClient` directly only for commands

A write has no ongoing state to track — it runs once and reports success or failure. Wrapping it in `httpResource()` buys nothing there; call `HttpClient` and handle the result at the call site.

```typescript
@Service() // v22+
export class OrderService {
  private readonly http = inject(HttpClient);

  placeOrder(order: NewOrder) {
    return this.http.post<Order>('/api/orders', order);
  }
}
```

Before v22, the same service is `@Injectable({ providedIn: 'root' })` — only the
decorator changes; the command itself is identical either way.

At the call site a command is one-shot, so `await` it rather than subscribing. A bare
`.subscribe()` is blocked by NG010 — the hook can't tell an HTTP Observable that
completes from one that never does — and `firstValueFrom()` is one of the teardowns it
accepts:

```typescript
async submit(order: NewOrder) {
  const placed = await firstValueFrom(this.orders.placeOrder(order));
  this.router.navigate(['/orders', placed.id]);
}
```

## 3. Never fetch in a component (NG106)

HTTP concerns belong in a service. A component that injects `HttpClient` directly also
tends to accumulate its own loading/error signals and an unmanaged subscription — see
`component-architecture` rule 1 for the full before/after. The service returns a
resource or an Observable; the component only reads it.

## 4. Independent requests run in parallel

Three unrelated reads, serialized for no reason.

Bad:

```typescript
async loadDashboard(userId: string) {
  const user = await firstValueFrom(this.http.get<User>(`/api/users/${userId}`));
  const orders = await firstValueFrom(this.http.get<Order[]>(`/api/orders?user=${userId}`));
  const notifications = await firstValueFrom(this.http.get<Notification[]>('/api/notifications'));
  return { user, orders, notifications };
}
```

Each `await` blocks on the previous response before the next request even starts — three
sequential round-trips where none of the three depends on another's result.

Start all three requests, then wait on the combined result.

Good:

```typescript
async loadDashboard(userId: string) {
  const [user, orders, notifications] = await Promise.all([
    firstValueFrom(this.http.get<User>(`/api/users/${userId}`)),
    firstValueFrom(this.http.get<Order[]>(`/api/orders?user=${userId}`)),
    firstValueFrom(this.http.get<Notification[]>('/api/notifications')),
  ]);
  return { user, orders, notifications };
}
```

One round-trip's worth of latency instead of three. The signal-based equivalent is three
independent `httpResource()`s read by the template directly — there's no `Promise.all`
to write because each resource already fetches as soon as it's created.

## 5. Interceptors are functions

Register with `withInterceptors([...])` in `provideHttpClient()`, not the class-based
`HttpInterceptor` pattern.

```typescript
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const token = inject(AuthService).token();
  return next(token ? req.clone({ setHeaders: { Authorization: `Bearer ${token}` } }) : req);
};

// app.config.ts
provideHttpClient(withInterceptors([authInterceptor]));
```

## 6. Handle errors at the boundary

Cross-cutting error handling — logging every failed request, redirecting to a login page
on 401 — belongs in an interceptor, once, for every request. A view-specific error (this
particular fetch failed, show this particular message) belongs in that view's own
`.error()` signal, not smuggled through the same interceptor.

```typescript
export const errorLoggingInterceptor: HttpInterceptorFn = (req, next) =>
  next(req).pipe(
    catchError((err: HttpErrorResponse) => {
      if (err.status === 401) inject(Router).navigateByUrl('/login');
      return throwError(() => err);
    }),
  );
```

```typescript
@Component({
  template: `
    @if (user.error()) {
      <p>Couldn't load this profile.</p>
    }
  `,
})
export class UserProfileComponent {
  private readonly userService = inject(UserService);
  readonly userId = input.required<string>();
  readonly user = this.userService.userResource(this.userId);
}
```

## 7. Never subscribe without teardown (NG010)

`httpResource()` and `toSignal()` never leave a dangling subscription — the resource
owns its own lifecycle, and `toSignal()` unsubscribes on the consuming context's
destruction. The risk is specifically a manual `.subscribe()` call. See `rxjs-interop`
rule 2 for the full pattern.

## 8. `resource()` for non-HTTP async, `rxResource()` for an existing Observable (v22+)

`resource()` wraps any promise-returning loader — reading a file, querying IndexedDB,
calling a third-party SDK that returns a promise. `rxResource()` is for the case where
the async source is already an Observable you don't control (a websocket wrapper, a
library that only exposes RxJS) and converting it to a promise first would be pointless
indirection. Both are v22+.

```typescript
readonly settingsResource = resource({ // v22+
  params: () => this.userId(),
  loader: ({ params }) => this.db.getSettings(params),
});
```

Before v22, wrap the promise-returning call in `from(...)` and convert with
`toSignal()` — the same boundary-conversion pattern as `signals-essentials` rule 8. It
loses `.isLoading()` and `.error()` as separate signals; that gap is exactly what
`resource()` closes once v22 is available.

## Reference

For `HttpClient` configuration, interceptor composition, and resource API detail, the
authority is Angular's own materials:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`
