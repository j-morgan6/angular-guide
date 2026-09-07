---
name: project-structure
description: MANDATORY for file naming and project layout. Invoke before creating files or directories in an Angular workspace.
file_patterns:
  - "**/*.ts"
  - "**/angular.json"
auto_suggest: true
---

# Project Structure

This skill follows Angular's official style guide rather than restating it. What it adds
is the layout judgment call an AI defaults wrong on when scaffolding a new feature:
type-first directories (`components/`, `services/`, `models/`) instead of feature-first
ones, and role-suffixed filenames left over from a pre-v20 style guide.

## RULES — Follow these with no exceptions

1. **Hyphenate filenames** — `user-profile.ts` for `UserProfile`
2. **Name by intent, not role** — v20+ style drops the `.component` / `.service` suffix requirement
3. **Organize by feature, never by type** — no top-level `components/` or `services/` directories
4. **One concept per file**
5. **Component files share a base name** — `.ts`, `.html`, `.css` together in one directory
6. **`src/` holds all UI code**, bootstrap in `src/main.ts`
7. **`protected` for template-only members**, `readonly` for Angular-initialized ones
8. **Name handlers for the action, not the event** — `saveUser()`, not `handleClick()`

## 1. Hyphenate filenames

`UserProfile` the class becomes `user-profile.ts` the file — kebab-case, no exceptions
for acronyms or multi-word type names.

Bad:

```
userProfile.ts
UserProfile.ts
```

Good:

```
user-profile.ts
```

## 2. Name by intent, not role

Angular's v20+ style guide no longer requires a `.component` / `.service` / `.directive`
suffix on every file — the class name itself already tells you what it is
(`UserProfile`, not `UserProfileComponent`, if the project has adopted the newer
convention). Pick one convention per project and apply it consistently; the anti-pattern
is not "which style" but drifting between both in the same codebase.

Inconsistent within one project:

Bad:

```
user-profile.component.ts   (old style)
order-summary.ts            (new style)
```

One convention, applied everywhere:

Good:

```
user-profile.ts
order-summary.ts
```

## 3. Organize by feature, never by type

A top-level `components/`, `services/`, or `models/` directory forces every change to a
single feature to touch three unrelated parts of the tree, and gives no signal about
which files belong together.

Bad:

```
src/app/
  components/
    user-profile.ts
    order-summary.ts
  services/
    user.service.ts
    order.service.ts
```

Good:

```
src/app/
  users/
    user-profile.ts
    user.service.ts
  orders/
    order-summary.ts
    order.service.ts
```

## 4. One concept per file

One component, one service, one directive, one significant type per file. A file mixing
a component and its data model, or two unrelated helper functions, makes both harder to
find and harder to move independently later.

## 5. Component files share a base name

A component's `.ts`, `.html`, and `.css` live together in one directory, sharing a base
name — `user-profile.ts`, `user-profile.html`, `user-profile.css` — rather than
scattering templates into a shared `templates/` directory or inlining every template as
a string.

## 6. `src/` holds all UI code, bootstrap in `src/main.ts`

Application code — components, services, routes, models — lives under `src/app/` (or
your project's equivalent root). `src/main.ts` is the one file that calls
`bootstrapApplication()`; it holds no feature logic of its own.

## 7. `protected` for template-only members, `readonly` for Angular-initialized ones

A member the template reads but nothing outside the class calls should be `protected`,
not `public` — `public` on a component is a promise that other TypeScript code depends
on it, which a template binding doesn't need. A member Angular sets up once at
construction (`inject()` results, `input()`, `computed()`) should be `readonly` — it
communicates that the binding itself never changes, even though a signal's value does.

```typescript
export class UserProfile {
  private readonly userService = inject(UserService);
  readonly userId = input.required<string>();
  protected readonly displayName = computed(() => this.userService.name(this.userId()));
}
```

## 8. Name handlers for the action, not the event

A method bound to `(click)` should describe what it does, not restate that it's a click
handler — the binding already says that.

Bad:

```typescript
export class SaveButton {
  handleClick() {
    this.userService.save(this.user());
  }
}
```

Good:

```typescript
export class SaveButton {
  saveUser() {
    this.userService.save(this.user());
  }
}
```

`saveUser()` still reads correctly from a call site that has nothing to do with clicking
— a keyboard shortcut, a test, a different template event bound to the same method.

## Reference

This skill deliberately does not restate Angular's own style guide or naming reference —
for the full rationale and edge cases, the authority is Angular's own materials:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`,
  specifically its `naming-conventions.md`
- `angular.dev/style-guide`
- `angular.dev/llms.txt`
