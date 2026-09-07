---
name: component-architecture
description: MANDATORY for ALL component design decisions. Invoke before creating a component or adding logic to an existing one.
file_patterns:
  - "**/*.component.ts"
  - "**/*.html"
auto_suggest: true
---

# Component Architecture

Angular's docs are deliberately neutral about where logic belongs — smart/dumb, container/
presentational, service-vs-component are conventions the framework doesn't enforce. That
neutrality is exactly why an AI defaults to putting everything in the component: it's the
path of least resistance, and it's also the top production anti-pattern this plugin exists
to stop.

## RULES — Follow these with no exceptions

1. **Components render; services decide** — no HTTP calls in a component (NG106)
2. **No direct `document` / `window`** — use `viewChild()`, `afterRenderEffect()`, inject `DOCUMENT` (NG105)
3. **Presentational components take inputs and emit outputs** — they inject nothing but presentation helpers
4. **One container per screen** — it orchestrates; its children render
5. **Past ~200 lines or ~8 inputs, split the component** (NG106)
6. **Validation and transformation belong in the service or a pure function**, never inline in a template
7. **Prefer a directive over a component** when adding behaviour to an existing element
8. **Templates hold no logic** — extract to a `computed()` or a method

## The centerpiece: pulling HTTP out of a component

This is the single most common thing an AI gets wrong when asked to "add a screen that
loads some data": it injects `HttpClient` directly into the component, adds a loading
flag and an error flag, and transforms the response inline in a subscribe callback. Every
part of that is wrong, and `resource()`/`httpResource()` (stable, v22) removes the reason
it ever happened.

Bad:

```typescript
@Component({
  selector: 'app-user-profile',
  template: `
    @if (loading()) {
      <p>Loading…</p>
    } @else if (error()) {
      <p>Something went wrong.</p>
    } @else {
      <h2>{{ displayName() }}</h2>
    }
  `,
})
export class UserProfileComponent {
  private readonly http = inject(HttpClient);
  readonly userId = input.required<string>();

  readonly loading = signal(true);
  readonly error = signal<string | null>(null);
  readonly displayName = signal('');

  constructor() {
    effect(() => {
      this.loading.set(true);
      this.http.get<User>(`/api/users/${this.userId()}`).subscribe({
        next: (user) => {
          this.displayName.set(`${user.firstName} ${user.lastName}`);
          this.loading.set(false);
        },
        error: (err) => {
          this.error.set(err.message);
          this.loading.set(false);
        },
      });
    });
  }
}
```

This component now owns HTTP concerns, three pieces of manually-synchronized state, a
subscription with no teardown, and a transformation (`firstName + lastName`) baked into
the fetch path where nothing else can reuse it.

Good:

A service exposes the `httpResource()`, and the component only reads it.

```typescript
// user.service.ts
@Service()
export class UserService {
  userResource(userId: () => string) {
    return httpResource<User>(() => `/api/users/${userId()}`);
  }
}
```

```typescript
// user-profile.component.ts
@Component({
  selector: 'app-user-profile',
  template: `
    @if (user.isLoading()) {
      <p>Loading…</p>
    } @else if (user.error()) {
      <p>Something went wrong.</p>
    } @else if (user.value(); as u) {
      <h2>{{ u.firstName }} {{ u.lastName }}</h2>
    }
  `,
})
export class UserProfileComponent {
  private readonly userService = inject(UserService);
  readonly userId = input.required<string>();
  readonly user = this.userService.userResource(this.userId);
}
```

The component now has one job — render three states of one resource — and the fetch
logic lives somewhere it can be reused, unit-tested without a `TestBed`, and read by more
than one screen.

## 2. No direct `document` / `window` in a component (NG105)

Direct global access breaks under server-side rendering, where neither global exists in
the form the browser provides. Use the framework's seams instead.

Bad:

```typescript
@Component({ selector: 'app-banner' })
export class BannerComponent {
  ngAfterViewInit() {
    document.querySelector('.banner')?.classList.add('visible');
  }
}
```

Good:

```typescript
@Component({
  selector: 'app-banner',
  template: `<div #banner class="banner">…</div>`,
})
export class BannerComponent {
  private readonly banner = viewChild.required<ElementRef<HTMLElement>>('banner');

  constructor() {
    afterRenderEffect(() => {
      this.banner().nativeElement.classList.add('visible');
    });
  }
}
```

When you genuinely need the document object itself (not an element), inject `DOCUMENT`
rather than reading the global — it's the same object in the browser and a safe stand-in
under SSR.

## 3. Presentational components take inputs and emit outputs

A presentational component's job is to render what it's given and report what happened.
It injects formatting or i18n helpers if it needs to, but never a data service — the
moment it does, it stops being reusable outside the one screen that happens to provide
that service.

```typescript
@Component({
  selector: 'app-rating-stars',
  template: `
    @for (i of [1, 2, 3, 4, 5]; track i) {
      <button (click)="rated.emit(i)" [class.filled]="i <= value()">★</button>
    }
  `,
})
export class RatingStarsComponent {
  readonly value = input.required<number>();
  readonly rated = output<number>();
}
```

## 4. One container per screen

A screen has exactly one component that knows *how the pieces fit together* — it injects
services, owns the resources, and passes slices of state down as inputs. Its children
don't independently decide to fetch data; they render what the container hands them and
emit events back up. Two components on the same screen both injecting the same service
independently is a sign the container boundary is missing, not that the service is
under-used.

## 5. Past ~200 lines or ~8 inputs, split the component (NG106)

Both are proxies for the same problem: the component is doing more than one job. Split by
extracting a presentational child (most common), or by moving non-rendering logic into a
service or pure function. An 8-input ceiling is a nudge toward passing one object input
(`readonly config = input.required<ProfileConfig>()`) rather than eight scalars, which
also tends to reveal that the eight scalars were really describing one concept.

## 6. Validation and transformation belong in a service or a pure function

Never in a template, and not inline in a component method either if the logic is
non-trivial. A pure function is easiest to unit test in isolation; a service is the right
home when the logic needs injected dependencies (locale, config, another service).

Bad:

```html
<p>{{ (item.price * item.quantity * (1 - item.discount)).toFixed(2) }}</p>
```

Good:

```typescript
export function lineTotal(item: LineItem): number {
  return item.price * item.quantity * (1 - item.discount);
}
```

```html
<p>{{ lineTotal(item) | currency }}</p>
```

## 7. Prefer a directive over a component for behaviour on an existing element

If what you're adding is behaviour attached to an element that already has its own
template — not new markup — a directive is the right shape. It composes onto any host
element instead of requiring callers to restructure their template around a new
component wrapper.

```typescript
@Directive({
  selector: '[appAutoFocus]',
})
export class AutoFocusDirective {
  private readonly el = inject(ElementRef<HTMLElement>);

  constructor() {
    afterRenderEffect(() => this.el.nativeElement.focus());
  }
}
```

## 8. Templates hold no logic

A template should read like a description of the UI, not contain a computation. Anything
beyond a direct property read or a trivial boolean belongs in a `computed()` or a method
on the component.

Bad:

```html
<p>{{ item.price * item.quantity * (1 - item.discount) }}</p>
```

Good:

```typescript
readonly lineTotal = computed(() => {
  const item = this.item();
  return item.price * item.quantity * (1 - item.discount);
});
```

```html
<p>{{ lineTotal() }}</p>
```

## Reference

For component API detail — lifecycle hooks, `viewChild()` options, directive host
metadata — the authority is Angular's own materials:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`
