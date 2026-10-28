---
name: tdd
description: Test-first changes in Broski. Use before changing any behavior or fixing any bug in BroskiCore, the Mac app or the iPhone app - write the failing test, watch it fail, make it pass, then run everything.
---

# Test-first in Broski

## The loop

1. **Name the behavior** the way the person would notice it: "a reply arriving while you read older messages doesn't pull you down", "a local-only project never reaches a cloud model".
2. **Put the logic in BroskiCore.** Views stay thin. If the logic sits in `Sources/Broski` or `iOS/`, move it down first (a pure function or a small type), then test it there.
3. **Write the test** in `Tests/BroskiCoreTests/<Area>Tests.swift` with Swift Testing:

   ```swift
   import Foundation
   import Testing
   @testable import BroskiCore

   @Suite("Model gateway")
   struct GatewayTests {
       @Test("a local-only project never reaches a cloud model")
       func localOnlyStaysLocal() async throws {
           // arrange with fakes, act, then #expect(...) on what the person would see
       }
   }
   ```

4. **Watch it fail:** `scripts/test.sh GatewayTests` (filter by the type name, not the display name). It must fail because the behavior is missing, not because it doesn't compile.
5. **Make it pass** with the simplest code that does. Then run `scripts/test.sh` with no filter: that run is recorded as green, and the Stop hook and the pre-commit hook check for it.
6. **Refactor** with the tests green. Run them again.

## Fakes, never the real thing

- **Models:** build a `ModelGateway` and set `makeConnector` to a fake `ModelConnector` that records each `ModelRequest` and returns a canned `ModelReply`. For wire formats, call the connector's static `body(for:model:)` and `parse(_:status:)`, or give it a fake `transport`. No test ever touches the network or spends money.
- **Files:** a fresh folder per test (`FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`), removed in `defer`. Never the person's Broski folder.
- **Time:** pass dates in (`at:`, `now:`) rather than reading the clock.
- **Devices:** two devices are two `device:` names ("mac", "iphone") writing their own files in the same temp folder.

## What every kind of change needs

- **A bug:** a test that reproduces the report and fails before the fix.
- **A stored format:** a round-trip test, and an upgrade test that reads a line from the previous version (written out literally in the test, the way `EfficiencyTests` keeps an old usage line).
- **A path that sends text off the device:** a privacy test that local-only projects and the vault never reach a cloud provider, and that nothing from private mode is written to the Broski folder (see the `model-provider` skill).
- **A screen:** logic in BroskiCore with unit tests, plus a `--snapshot` render before and after (see `broski-ui`). Interaction (keys, scrolling) goes in `Sources/Broski/ChatCheck.swift`, which drives the real views off screen.

## Check the test can fail

For a test that guards something important (privacy, data loss, money), break the code on purpose once, see the test fail, and put the code back. A test that can't fail protects nothing.

## Done means

- `scripts/test.sh` green with no filter, and `scripts/ci.sh` before the commit (`--ios` when shared or iPhone code changed).
- You can say which test shows the change works, and what you didn't verify.
