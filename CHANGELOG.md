# Changelog

All notable changes to `angular-guide` are documented in this file.

## Unreleased

### Fixed

- **Subagent rule injection now works.** `SubagentStart` output was plain stdout, which
  Claude Code writes to its debug log rather than the subagent's context. It is now JSON
  `hookSpecificOutput.additionalContext`. It is also only emitted inside an Angular
  workspace (a cached profile exists), and only includes the rules the workspace's
  profile enables — a v20 subagent is no longer told OnPush is the default.
- **Skill scoping now works.** `file_patterns` and `auto_suggest` are not Claude Code
  skill fields and were ignored; skills now use `paths`. Every skill description names
  Angular, so the skills are less likely to load in non-Angular TypeScript projects.
- Skills used `resource()`'s pre-v20 `request` option; they now use `params`.
- NG010 no longer misses a teardown that precedes an arrow-function operator in the same
  `pipe()`, and no longer credits an enclosing call's `take(` to an inner `.subscribe()`.
- NG012 no longer flags two-argument `.set(k, v)` calls (`Map`, `HttpParams`,
  `URLSearchParams`, `FormData`) inside an effect. Its message no longer suggests
  `untracked()` as a general way out.
- NG016 judges the value, not just the key name: `storageKey: "app-theme"`, `hotkey`,
  Firebase `apiKey` (`AIza…`) and Stripe publishable keys no longer block.
- NG105 no longer flags `this.document` from `inject(DOCUMENT)` — the rule's own fix.

- **Security:** every hook now runs Python in isolated mode (`-I`). Before, a
  repository containing `json.py`, `tempfile.py` or `datetime.py` had that file executed
  by every hook, SessionStart included.

### Changed

- **The workspace profile no longer lives in your repository.** It is cached under
  `$CLAUDE_PLUGIN_DATA` (or `$XDG_CACHE_HOME/angular-guide`), so there is nothing to
  gitignore; an old `.angular-guide-project.json` can be deleted. Hooks detect a
  workspace on first use and re-detect when `package.json`, `angular.json`,
  `tsconfig.json` or a lockfile changes, so `ng update` mid-session takes effect
  immediately. A monorepo session started at the repo root now also reaches the
  subagent and Bash hooks.
- **The Bash guard only runs inside an Angular workspace, and parses commands** instead
  of matching text. Quoted text (an `echo`, a commit message) no longer triggers a rule,
  and a flag is only credited to the command it belongs to. It now also catches
  `npx ng ...`, `bash -c "..."`, `+main` refspecs, `-fu`-style combined flags,
  `git push -f origin HEAD`, `rm` of a lockfile without `-r`, and `npm`/`pnpm`/`yarn test`
  when the `test` script runs `ng test` in watch mode.
- **Blocking rules only block what a change adds.** Each NG0xx rule runs on the file
  before and after the change, and blocks only if it matches more times after. An
  unrelated edit to a file with older code in it now goes through; adding another
  instance of a rule the file already breaks is still blocked, with a note saying how
  many were already there.
- The Write/Edit rules moved from `hook-lint.sh` (bash plus eight inline Python passes)
  into one Python module, `scripts/lint.py`. A pre-write check takes about 30 ms
  instead of about 200 ms. NG103 now also matches `@Injectable({ ... })` split across
  lines.
- The plugin version is read from `VERSION` rather than a copy in `detect_project.sh`.

- `data-loading` shows the call-site pattern for HTTP commands
  (`await firstValueFrom(...)`), which NG010 accepts.

## 1.0.0 — 2026-09-06

Initial release.

### Added

- **Nine skills**: `angular-essentials`, `signals-essentials`, `rxjs-interop`,
  `component-architecture`, `state-management`, `data-loading`, `testing-essentials`,
  `performance-and-zoneless`, `project-structure`. Each loads automatically based on the
  file being edited and covers the judgment calls Angular's own documentation
  deliberately leaves open — which reactive primitive to reach for, where component
  logic should live, when to escalate state to a shared store.
- **Thirty deterministic rules**, wired into native Claude Code hooks
  (`hooks/hooks.json`, no install script, nothing written to `~/.claude/settings.json`):
  - `BG001`–`BG006` — a `PreToolUse` Bash guard catching a force-push to the default
    branch, the removed `ng build --prod` flag, a package-manager/lockfile mismatch, a
    hanging `ng test` invocation, deleting a lockfile alongside `node_modules`, and
    `ng update --force`.
  - `NG001`–`NG018` — blocking `PreToolUse` checks on `Write`/`Edit`, run against the
    effective post-edit content: legacy Angular idioms (`@NgModule`, `*ngIf`/`*ngFor`,
    constructor injection, decorator `@Input()`/`@Output()`, explicit `OnPush`), signal
    misuse (`.mutate()`, effects that write signals, missing `@for` `track`), and
    security/workspace hygiene (`[innerHTML]`, `bypassSecurityTrust*`, secrets in
    `environment*.ts`, stray `zone.js` in a zoneless workspace, Jasmine in a Vitest
    workspace).
  - `NG101`–`NG106` — advisory `PostToolUse` checks against the file already on disk:
    eager route components, Reactive Forms where Signal Forms are available,
    `@Injectable({ providedIn: 'root' })` where `@Service()` is available, un-optimized
    `<img>` tags, direct `document`/`window` access in a component, and component
    structural complexity (HTTP calls, line count, input count).
- **Three read-only review agents** (`Read`, `Grep`, `Glob` only — no write tools):
  `angular-architecture-review`, `signals-review`, `angular-project-structure`. Each is
  meant to be dispatched after a feature is written, to catch what the write-time hooks
  can't — logic that's technically valid but landed in the wrong layer.
- **Version-aware detection**: a `SessionStart` hook (`scripts/detect_project.sh`) reads
  the workspace's Angular version from `package.json` or, failing that, its lockfile,
  and writes a cached profile (`.angular-guide-project.json`) that gates every
  version-sensitive rule. An unknown version disables the gated rules rather than
  guessing at them.
- Full test suite (`tests/run-tests.sh`, bash + python3, no `jq`) — 130 checks, including
  drift checks that fail the build if a skill or `subagent-rules.sh` cites a rule ID no
  script implements, or if the README stops documenting an implemented rule.
