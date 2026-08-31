# Engineering Guidelines

## State and architecture

- Use Swift Observation (`@Observable`) for app-owned state. Do not mix it with `ObservableObject` or `@Published`.
- Use closed state enums for finite lifecycles and modes.
- Model events as explicit transition methods. Avoid scattered boolean guards and implicit state changes.
- Give each lifecycle one idempotent teardown path.
- Keep prompt composition and other data transformations pure and outside views.
- Do not add The Composable Architecture piecemeal. Use the native Observation model consistently.

## Concurrency

- Give each asynchronous task one clear owner.
- Never use `Task.detached` for work owned by a capture, panel, window, or feature lifecycle.
- Retain lifecycle task handles, cancel them during teardown, and clear them.
- Treat cancellation as cooperative: check it before and after external calls.
- Before applying a late result, verify its capture token, annotation ID, and original session ID.
- Keep UI state and UI mutations on `@MainActor`.

## Boundaries and tests

- Inject filesystem, pasteboard, provenance, permission, and other system boundaries where deterministic tests need substitutes.
- Test observable state transitions and behavior, not source layout or implementation details.
- Cover cancellation, stale-result rejection, invalid transitions, and teardown paths.
- Prefer a small explicit dependency boundary over a framework or protocol hierarchy.
- Make clean cutovers: remove obsolete callers, state fields, settings keys, imports, and files.
