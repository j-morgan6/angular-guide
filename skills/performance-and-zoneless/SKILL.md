---
name: performance-and-zoneless
description: MANDATORY for Angular zoneless, change detection, and bundle work. Invoke before touching change detection, defer blocks, route loading, or images.
paths:
  - "**/*.ts"
  - "**/*.html"
---

# Performance and Zoneless

Angular's docs explain zoneless, `@defer`, and `NgOptimizedImage` as independent
features. They don't warn you that removing zone.js quietly breaks code that used to
work by accident — that's the single most expensive migration bug, and it's the reason
this skill exists as one topic rather than three.

## RULES — Follow these with no exceptions

1. **Never set `OnPush` explicitly on v22+** — it is the default (NG006)
2. **Never import `zone.js` in a zoneless workspace** (NG017)
3. **In zoneless apps, state changes must go through signals** — a plain field mutation will not schedule a render
4. **Lazy-load every feature route** (NG101)
5. **`@defer` for below-the-fold and heavy components**, with a `@placeholder`
6. **Every `@for` needs `track`** (NG013)
7. **`NgOptimizedImage` for every static image** (NG104)
8. **Measure before optimizing** — `ng build --stats-json`, then the bundle analyzer

## 1. Never set `OnPush` explicitly on v22+ (NG006)

`ChangeDetectionStrategy.OnPush` is the default component strategy starting in Angular
v22 — writing it is dead code that also signals the author doesn't know it's already on.

Bad:

```typescript
@Component({
  selector: 'app-widget',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class Widget {}
```

Good:

```typescript
@Component({
  selector: 'app-widget',
})
export class Widget {}
```

## 2. Never import `zone.js` in a zoneless workspace (NG017)

Zoneless is the default for new projects since v21. A zoneless app boots with
`provideZonelessChangeDetection()` and no `zone.js` dependency; importing it back
re-introduces monkey-patching of every async API and cancels out the reason zoneless
was chosen.

Bad:

```typescript
import 'zone.js';
```

The fix is to delete the import outright — a zoneless workspace has no `zone.js`
dependency to import in the first place.

## 3. In zoneless apps, state changes must go through signals

This is the failure mode that costs the most migration time, and it fails silently: the
code runs, no error is thrown, and the view just stops updating.

Under zone.js, *any* async callback — a `setTimeout`, a promise resolution, a DOM event
— triggered a full change-detection pass regardless of whether Angular tracked what
changed. That meant a plain mutable field, reassigned inside a callback, still rendered
correctly: zone.js's blanket detection covered for it. Remove zone.js and that safety
net is gone. Angular now only knows to re-render when a signal it's watching changes.
A field mutation is invisible to it.

This worked under zone.js and goes silently stale once zoneless.

Bad:

```typescript
@Component({
  selector: 'app-order-status',
  template: `<p>Status: {{ status }}</p>`,
})
export class OrderStatusComponent {
  private readonly orders = inject(OrdersService);
  readonly orderId = input.required<string>();
  status = 'pending';

  constructor() {
    this.orders.watch(this.orderId()).then((s) => {
      this.status = s; // reassigns a plain field — nothing schedules a render
    });
  }
}
```

On v22+, `resource()` is the built-in fix.

Good:

```typescript
@Component({
  selector: 'app-order-status',
  template: `<p>Status: {{ status.value() }}</p>`,
})
export class OrderStatusComponent {
  private readonly orders = inject(OrdersService);
  readonly orderId = input.required<string>();
  readonly status = resource({ // v22+
    params: () => this.orderId(),
    loader: ({ params }) => this.orders.watch(params),
  });
}
```

Before v22, the minimal fix is the same shape without `resource()` — a signal, written
with `.set()` instead of a plain field reassignment:

```typescript
@Component({
  selector: 'app-order-status',
  template: `<p>Status: {{ status() }}</p>`,
})
export class OrderStatusComponent {
  private readonly orders = inject(OrdersService);
  readonly orderId = input.required<string>();
  readonly status = signal('pending');

  constructor() {
    this.orders.watch(this.orderId()).then((s) => this.status.set(s));
  }
}
```

Both fixes turn on the same thing: writing to something Angular's reactive graph
tracks, instead of a field it can't see. `resource()` additionally models loading and
error state for you — the signal-only version doesn't, which is the gap `resource()`
closes once v22 is available.

Anywhere a callback — a timer, a WebSocket handler, a third-party SDK's completion
callback — used to "just work" by way of zone.js noticing *something* happened, it now
needs to write to a signal explicitly, or the change is real but invisible to the view.

## 4. Lazy-load every feature route (NG101)

An eager `component:` reference pulls that feature into the initial bundle regardless of
whether the user ever visits the route.

Bad:

```typescript
export const routes: Routes = [
  { path: 'admin', component: AdminPage },
];
```

Good:

```typescript
export const routes: Routes = [
  { path: 'admin', loadComponent: () => import('./admin/admin-page').then((m) => m.AdminPage) },
];
```

A small shell route (the app frame itself) is a defensible exception; a feature screen
almost never is.

## 5. `@defer` for below-the-fold and heavy components, with a `@placeholder`

`@defer` moves a template block's component code into a separate chunk, loaded on the
trigger you specify (viewport entry, interaction, idle, or a timer). Always pair it with
a `@placeholder` so there's no layout jump when the deferred content resolves.

```html
@defer (on viewport) {
  <app-comments [postId]="postId()" />
} @placeholder {
  <div class="comments-placeholder"></div>
} @loading (minimum 200ms) {
  <app-spinner />
}
```

## 6. Every `@for` needs `track` (NG013)

Without a `track` expression, Angular cannot tell which DOM node corresponds to which
data item across a re-render — it discards and rebuilds the whole list instead of
patching the items that changed.

Bad:

```html
@for (item of items()) {
  <app-row [item]="item" />
}
```

Good:

```html
@for (item of items(); track item.id) {
  <app-row [item]="item" />
}
```

`track $index` technically satisfies the rule but usually defeats its purpose: when the
list reorders or filters, the index stays stable but the item at that index doesn't, so
Angular reuses the wrong node's state. Track a real identity — `item.id` — not the
position.

## 7. `NgOptimizedImage` for every static image (NG104)

A raw `<img src="...">` gets none of the lazy loading, `srcset` generation, or priority
hints that cause the most common Core Web Vitals regression — layout shift and slow
largest-contentful-paint from unoptimized hero images.

Bad:

```html
<img src="/assets/hero.png" alt="Product hero" />
```

Good:

```html
<img ngSrc="/assets/hero.png" width="800" height="600" alt="Product hero" priority />
```

`priority` is for the one or two images above the fold that should load eagerly instead
of lazily — don't add it to every image or it defeats lazy loading entirely.

## 8. Measure before optimizing

Bundle size and change-detection cost are both measurable; guessing which component or
chunk is the problem wastes the optimization budget on the wrong target.

```bash
ng build --stats-json
npx webpack-bundle-analyzer dist/*/stats.json
```

For change-detection cost specifically, Angular DevTools' profiler shows which
components re-render and how often — reach for it before assuming a slow view needs
`OnPush` tuning it may already have by default (rule 1).

## Reference

For zoneless migration steps, `@defer` trigger syntax, and `NgOptimizedImage`
configuration options, the authority is Angular's own materials:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`
