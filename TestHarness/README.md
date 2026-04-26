# Loot TestHarness

Headless SPM package for unit-testing pure-Foundation code from the Loot
iMessage extension without invoking xcodebuild.

## Run

```sh
cd TestHarness
swift test
```

## What's covered (~144 tests)

The `LootDomain` target symlinks `Sources/LootDomain` →
`../Loot MessagesExtension/Domain`. The same Swift files compiled here
ship in the iOS extension — no duplicated code.

| Type                              | Tests | File                              |
|-----------------------------------|-------|-----------------------------------|
| `Money`                           | 40    | `MoneyTests.swift`                |
| `PersonID`, `Person`              | 19    | `PersonTests.swift`               |
| `LineItem`, `AuxLine`             | 18    | `LineItemTests.swift`             |
| `LineItemForm`, `AuxLineForm`     | 24    | `LineItemFormTests.swift` + `LineItemFormBridgeRegressionTests.swift` |
| `ReceiptBreakdown`, `Receipt`     | 15    | `ReceiptTests.swift`              |
| `SplitMode`, `SplitConfiguration` | 22    | `SplitConfigurationTests.swift`   |

## What's NOT covered (and why)

- **Wire-format round-trips** (`LootMessageCodec`, `SplitPayload.from(draft:)`,
  `LootMessagePayload.toReceiptDisplay()`). These live in
  `Loot MessagesExtension/Utilities/LootMessagePayload.swift`. The file mixes
  pure-Foundation wire structs (`LootMessagePayload`, `ReceiptPayload`,
  `SplitPayload`) with adapter extensions that import SwiftUI / Messages
  / Firebase types via `SplitDraft`, `ReceiptDisplay`, and `LootTab`. A
  whole-file symlink fails to compile in the SPM target. **Phase 2.9 of the
  refactor** splits this into `Wire/WirePayload.swift` (pure) +
  `Utilities/LootMessagePayloadAdapters.swift` (impure); after that, the pure
  half can be symlinked and round-trip tests added.

- **`SplitMath.computeOwedCents`** (the byItems / equally / custom math).
  Lives in `Loot MessagesExtension/Utilities/MoneyHelpers.swift`, but its
  signature uses `SplitPayload.Mode` and `SplitPayload.Guest` from
  `LootMessagePayload.swift`. Same blocker as above. Phase 2.9 unblocks
  this; alternatively, Phase 2.8 (SplitGuest → Person) could port the
  signature to use Domain types directly.

- **SwiftUI views and bindings.** `@State` / `@Binding` lifecycle is what
  caused most bugs we hit during Phase 2.6 (e.g. the dual-source-of-truth
  splitDraft mirror, the UUID mismatch between `guests` and `draftGuests`).
  Phase 3 of the refactor extracts `LootUIModel` into per-feature
  ViewModels (`ReceiptDraftViewModel`, `MessageReceiptViewModel`, etc.)
  that are plain `ObservableObject`s — testable on macOS without UIKit /
  SwiftUI emulation. **The refactor itself is the testability improvement.**

- **Firestore I/O** (`SharedReceiptService`, `TabService`). Requires the
  Firebase SDK + a credential or local emulator. To test these, set up
  the Firebase Emulator Suite (`firebase emulators:start --only firestore`)
  and gate `SharedReceiptService.configureFirebase` to point at
  `localhost:8080` when `LOOT_USE_EMULATOR=1` env var is set.

- **Messages framework calls** (`MSConversation.send`, `MSSession`,
  bubble layout, etc.). Not testable headlessly. Manual device verification
  remains the only signal here.

## How to expand after Phase 2.9 lands

1. Confirm `Wire/WirePayload.swift` exists and contains only types that
   import `Foundation`.
2. `cd TestHarness && ln -s "../../Loot MessagesExtension/Wire" Sources/LootWire`
3. Add a target in `Package.swift`:
   ```swift
   .target(name: "LootWire", path: "Sources/LootWire")
   ```
4. If the new target needs `Money` / `PersonID` / etc., add
   `dependencies: ["LootDomain"]`.
5. Add the new target to `LootDomainTests` dependencies.
6. Write tests for `LootMessageCodec.payload(from:)`,
   `[SplitPayload.Guest].slotIndex(for:)`, etc.

Apply the same pattern for `MoneyHelpers.swift` once it no longer
mixes SplitPayload types with pure-Foundation ones.

## Backstop guarantees these tests provide

- Money parsing handles all current input shapes ("$X.XX", "X.XX",
  "1,234.56", " ", "", "12.5", "12.567", negative inputs).
- Money arithmetic + Codable round-trip is lossless.
- PersonID equality is by raw value; `newGuest()` produces unique IDs.
- LineItem `committed()` correctly trims label and reflects working
  set into canonical `assigneeIDs` (regression for the Phase 2.6 bug
  where the @State + array-subscript path silently dropped Set.insert
  mutations).
- SplitConfiguration `togglingIncluded` / `togglingPaid` are pure
  functions (no surprises with reference semantics).
- Receipt `lineItemSubtotalCents` and `completedLines` filter
  whitespace correctly.

These cover the "logic" half of bugs. The "framework integration" half
(in-place bubble updates, MSSession reuse, Firestore lag, SwiftUI
binding edge cases) still requires device testing.
