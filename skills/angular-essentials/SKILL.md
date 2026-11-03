---
name: angular-essentials
description: MANDATORY for ALL Angular code changes. Invoke before writing any .ts or .html file in an Angular workspace.
paths:
  - "**/*.ts"
  - "**/*.html"
---

# Angular Essentials

## RULES — Follow these with no exceptions

1. **Never write `standalone: true`** — standalone is the default since v20 (NG001)
2. **Never create an `@NgModule`** — use standalone components and route-level providers (NG002)
3. **Use native control flow** `@if` / `@for` / `@switch`, never `*ngIf` / `*ngFor` / `*ngSwitch` (NG003)
4. **Use `inject()`**, never constructor-parameter injection (NG004)
5. **Use `input()` / `output()` / `model()`**, never `@Input()` / `@Output()` decorators (NG005)
6. **Never set `changeDetection: OnPush`** — it is the default in v22 (NG006)
7. **Never use `any`** — use `unknown` and narrow it (NG007)
8. **Use `[class.x]` / `[style.x]` bindings**, never `ngClass` / `ngStyle` (NG008)
9. **Use the `host` object**, never `@HostBinding` / `@HostListener` (NG009)
10. **Never bind `[innerHTML]` and never call `bypassSecurityTrust*`** (NG014, NG015)

## 1. No `standalone: true` (NG001)

Standalone is the default since Angular v20 — writing it is redundant and signals a pre-v20 mental model. Delete the property.

Bad:

```typescript
@Component({
  selector: "app-widget",
  standalone: true,
  template: `...`,
})
export class Widget {}
```

Good:

```typescript
@Component({
  selector: "app-widget",
  template: `...`,
})
export class Widget {}
```

## 2. No `@NgModule` (NG002)

Use standalone components. Put shared providers in `providers` at bootstrap or on a route, and import components directly via the `imports` array.

Bad:

```typescript
@NgModule({
  declarations: [Widget],
  imports: [CommonModule],
})
export class WidgetModule {}
```

Good:

```typescript
@Component({
  selector: "app-widget",
  imports: [CommonModule],
  template: `...`,
})
export class Widget {}
```

## 3. Native control flow (NG003)

Use native control flow — `@if (cond) { }`, `@for (x of xs; track x.id) { }`, `@switch (v) { @case (a) { } }`. It needs no imports, is faster, and is the only supported form going forward.

Bad:

```html
<div *ngIf="isVisible">Hello</div>
<li *ngFor="let item of items">{{ item.name }}</li>
```

Good:

```html
@if (isVisible()) {
<div>Hello</div>
} @for (item of items(); track item.id) {
<li>{{ item.name }}</li>
}
```

## 4. `inject()`, not constructor-parameter injection (NG004)

Use the `inject()` function at field level. It gives better type inference, works in field initializers and functional guards/interceptors, and avoids inheritance boilerplate.

This check only fires in a file that already carries an Angular class decorator (`@Component`, `@Directive`, `@Injectable`, `@Service`, `@Pipe`, or `@NgModule`) — constructor-parameter properties on a plain, non-Angular class (e.g. a `Money` value class) are ordinary TypeScript and are not flagged.

Bad:

```typescript
@Component({ ... })
export class Widget {
  constructor(private http: HttpClient) {}
}
```

Good:

```typescript
@Component({ ... })
export class Widget {
  private readonly http = inject(HttpClient);
}
```

## 5. `input()` / `output()` / `model()`, not decorators (NG005)

Use the signal-based functions. Signal inputs are readable in `computed()` without a lifecycle hook.

Bad:

```typescript
export class Widget {
  @Input() name!: string;
  @Output() saved = new EventEmitter<Item>();
}
```

Good:

```typescript
export class Widget {
  readonly name = input.required<string>();
  readonly saved = output<Item>();
  readonly value = model<string>("");
}
```

## 6. No explicit `OnPush` (NG006)

OnPush is the default strategy in Angular v22 — setting it explicitly is now noise. Delete the property and its import.

Bad:

```typescript
@Component({
  selector: "app-widget",
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class Widget {}
```

Good:

```typescript
@Component({
  selector: "app-widget",
})
export class Widget {}
```

## 7. No `any` (NG007)

Use `unknown` when the type is genuinely uncertain and narrow it, or give the value its real type. `any` disables every check TypeScript exists to provide.

Bad:

```typescript
function parse(data: any) {
  return data.value;
}
```

Good:

```typescript
function parse(data: unknown) {
  if (typeof data === "object" && data !== null && "value" in data) {
    return (data as { value: string }).value;
  }
}
```

## 8. Native class/style bindings (NG008)

Use native bindings — `[class.active]="isActive()"`, `[style.width.px]="w()"`, or `[class]="classRecord()"`. They need no import and avoid an extra directive instance per element.

Bad:

```html
<div [ngClass]="{ active: isActive }" [ngStyle]="{ width: w + 'px' }"></div>
```

Good:

```html
<div [class.active]="isActive()" [style.width.px]="w()"></div>
```

## 9. The `host` object, not `@HostBinding` / `@HostListener` (NG009)

Use the `host` object in the decorator metadata. It keeps host behaviour in one place and is statically analysable.

Bad:

```typescript
export class Widget {
  @HostBinding("class.active") isActive = false;
  @HostListener("click", ["$event"]) onClick(e: Event) {}
}
```

Good:

```typescript
@Component({
  host: {
    "[class.active]": "isActive()",
    "(click)": "onClick($event)",
  },
})
export class Widget {}
```

## 10. No `[innerHTML]`, no `bypassSecurityTrust*` (NG014, NG015)

Render text with interpolation, or compose real components. `[innerHTML]` is sanitized by Angular, but the pattern still invites XSS as soon as someone reaches for `bypassSecurityTrust*`, which disables that protection outright. Sanitize upstream and render normally; if a genuine trusted-value case exists, it belongs in one reviewed, narrowly-scoped helper — never inline in a component.

Bad:

```typescript
@Component({
  template: `<div [innerHTML]="rawHtml"></div>`,
})
export class Widget {
  rawHtml = this.sanitizer.bypassSecurityTrustHtml(userInput);
}
```

Good:

```typescript
@Component({
  template: `<div>{{ text() }}</div>`,
})
export class Widget {
  readonly text = input.required<string>();
}
```

## Reference

This skill covers only the rules enforced by this plugin's hooks. For everything else — API detail, migration guidance, general Angular authorship — the authority is Angular's own tooling:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`

This skill deliberately does not restate Angular's reference documentation.
