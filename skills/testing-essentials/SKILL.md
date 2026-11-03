---
name: testing-essentials
description: MANDATORY for ALL Angular test files. Invoke before writing any .spec.ts file.
paths:
  - "**/*.spec.ts"
  - "**/*.test.ts"
---

# Testing Essentials

Angular's own docs still show Jasmine in most examples, because Vitest only became the
default runner in v21 and old material doesn't retroactively update. A model trained on
that material writes `jasmine.createSpy()` into a workspace that has no Jasmine
installed at all. This skill is the correction, plus the judgment Angular's docs don't
give on what a test should actually assert.

## RULES — Follow these with no exceptions

1. **Vitest is the runner on v21+** — `vi.fn()`, `vi.spyOn()`, never Jasmine APIs (NG018)
2. **TestBed is unchanged** — the runner swapped; the Angular testing API did not
3. **Test behaviour through the template**, not method calls on the instance
4. **Use component harnesses** for anything with a public interaction surface
5. **`RouterTestingHarness` for navigation**, never a hand-rolled router mock
6. **Never test framework behaviour** — that inputs bind or outputs emit is Angular's test, not yours
7. **`provideHttpClientTesting()` for HTTP** — assert on the request, not on a stubbed service
8. **Run non-interactively** — `ng test --run` / `--watch=false` (BG004)

## 1. Vitest is the runner on v21+ (NG018)

Vitest replaced Karma as Angular's standard test runner starting in v21. Before v21,
Karma with Jasmine is standard. Never mix vocabularies: a Vitest workspace has no
`jasmine` global, so `jasmine.createSpy()` or `spyOn()` fails at runtime, not just in
review.

This is Jasmine, written into a Vitest workspace.

Bad:

```typescript
it('calls save on submit', () => {
  const spy = jasmine.createSpy('save');
  component.onSave = spy;
  component.submit();
  expect(spy).toHaveBeenCalledWith(jasmine.objectContaining({ id: 1 }));
});
```

Good:

```typescript
it('calls save on submit', () => {
  const spy = vi.fn();
  component.onSave = spy;
  component.submit();
  expect(spy).toHaveBeenCalledWith(expect.objectContaining({ id: 1 }));
});
```

### Jasmine → Vitest migration table

| Jasmine | Vitest |
|---|---|
| `jasmine.createSpy('name')` | `vi.fn()` |
| `spyOn(obj, 'method')` | `vi.spyOn(obj, 'method')` |
| `spyOn(obj, 'method').and.returnValue(x)` | `vi.spyOn(obj, 'method').mockReturnValue(x)` |
| `jasmine.objectContaining({...})` | `expect.objectContaining({...})` |
| `jasmine.any(String)` | `expect.any(String)` |
| `fail('message')` | `expect.fail('message')` |
| `jasmine.clock().install()` | `vi.useFakeTimers()` |

## 2. TestBed is unchanged

The runner swapped; `TestBed.configureTestingModule()`, `TestBed.createComponent()`,
`fixture.detectChanges()`, and `fixture.debugElement` are exactly the API they were
under Karma. Don't reach for a Vitest-specific replacement for any of these — none
exists, because none is needed.

```typescript
beforeEach(async () => {
  await TestBed.configureTestingModule({
    imports: [UserProfileComponent],
    providers: [provideHttpClientTesting()],
  }).compileComponents();
});
```

## 3. Test behaviour through the template

A test that calls a private method or reads a private field is coupled to
implementation, not behavior — it breaks on a refactor that changes nothing a user could
observe.

Bad:

```typescript
it('increments count', () => {
  const fixture = TestBed.createComponent(CounterComponent);
  const component = fixture.componentInstance as unknown as { count: WritableSignal<number> };
  component.count.set(component.count() + 1);
  expect(component.count()).toBe(1);
});
```

Good:

```typescript
it('increments count when the button is clicked', () => {
  const fixture = TestBed.createComponent(CounterComponent);
  fixture.detectChanges();
  const button = fixture.debugElement.query(By.css('button'));
  button.triggerEventHandler('click');
  fixture.detectChanges();
  expect(fixture.debugElement.query(By.css('.count')).nativeElement.textContent).toContain('1');
});
```

The second test still passes if `count` is renamed or its update logic is refactored —
it only breaks if the button stops incrementing the displayed count, which is the actual
behavior being tested.

## 4. Use component harnesses

For anything with a real interaction surface — Material components, or your own
components exposing a `ComponentHarness` — use the harness instead of querying internal
DOM structure directly. A harness survives internal markup changes that a raw
`By.css()` selector does not.

```typescript
it('opens the menu on click', async () => {
  const fixture = TestBed.createComponent(ToolbarComponent);
  const loader = TestbedHarnessEnvironment.loader(fixture);
  const menuButton = await loader.getHarness(MatButtonHarness.with({ selector: '.menu-trigger' }));
  await menuButton.click();
  expect(await loader.getHarness(MatMenuHarness)).toBeTruthy();
});
```

## 5. `RouterTestingHarness` for navigation

Don't hand-roll a router mock with a fake `navigate()` spy and manually-constructed
`ActivatedRoute` stubs. `RouterTestingHarness` drives real navigation through the real
router configuration, which is what actually exercises guards, resolvers, and route
matching.

```typescript
it('navigates to the detail route', async () => {
  const harness = await RouterTestingHarness.create();
  const component = await harness.navigateByUrl('/items/42', ItemDetailComponent);
  expect(component.itemId()).toBe('42');
});
```

## 6. Never test framework behaviour

A test asserting that setting an `input()` updates the property, or that calling
`.emit()` on an `output()` fires the subscriber, is testing Angular's own guarantees —
Angular's test suite already covers that, and it will pass regardless of whether your
component logic is correct. Test what *your* code does with the input, not that the
input mechanism works.

## 7. `provideHttpClientTesting()` for HTTP

Register `provideHttpClientTesting()` and assert on the requests `HttpTestingController`
observed — method, URL, body — rather than replacing the service under test with a
hand-written stub that duplicates its interface.

```typescript
it('requests the user by id', () => {
  TestBed.configureTestingModule({ providers: [provideHttpClient(), provideHttpClientTesting()] });
  const httpMock = TestBed.inject(HttpTestingController);
  const service = TestBed.inject(UserService);

  service.getUser('42').subscribe();

  const req = httpMock.expectOne('/api/users/42');
  expect(req.request.method).toBe('GET');
  req.flush({ id: '42', name: 'Ada' });
  httpMock.verify();
});
```

## 8. Run non-interactively (BG004)

`ng test` runs in watch mode by default and never exits, which hangs an agent session
waiting on a command that was never going to finish. Always pass `--watch=false`
(Karma) or `--run` (Vitest) — or their CI equivalents — when running tests from a
script or an agent.

```bash
ng test --run
```

## Reference

For Jasmine/Karma-era conventions being phased out, TestBed API detail, and
harness authoring, the authority is Angular's own materials:

- Angular's agent skill: `angular/angular` → `skills/dev-skills/angular-developer/`
- Angular's CLI MCP server: `npx @angular/cli mcp`
- `angular.dev/llms.txt`
- Vitest documentation, for runner-specific API (`vi.mock`, `vi.useFakeTimers`, config)
