# CloudChess Unlimited — monetization branch

Digital puzzle access uses Apple's StoreKit 2 auto-renewable subscriptions (not
Apple Pay). Product `com.maroon.CloudChess.unlimited.monthly` belongs to group
22452898, App Store Connect product 6820353989. The US base price is $7.99/month;
other storefronts use Apple's localized prices and currency. The app always
shows `Product.displayPrice`, and disables purchasing if Apple cannot load it.

Free play allows three newly delivered puzzles in any rolling 60-minute window
on this device. Each slot refills one hour after that puzzle was delivered.
Opening instructions, retries, undo, backgrounding, and resuming the same saved
puzzle do not consume another slot. Generation failures do not consume a slot.
A skipped or failed puzzle has already consumed its slot. The current puzzle
can always be finished. A verified subscriber gets unlimited new puzzles.

The ledger is stored in this app's device-only Keychain. Durable admission is
idempotent by session UUID, including interruption between ledger and game saves.
It is not a server-side account quota: it does not synchronize across devices,
and cannot defend against every deliberate clock or device-state manipulation.
Backward clock changes never refill; elapsed time remains monotonic in-process.
No payment credentials or Apple Account passwords are collected by CloudChess.

Only Apple's verified, current entitlement grants paid access. Pending, canceled,
failed and unverified purchases never unlock. Transaction updates, foreground,
expiry and periodic refresh reconcile revocations and renewals. Restore purchases
explicitly invokes AppStore.sync; a manage-subscription sheet is available while
subscribed. Test-only quota fixtures compile out of Release; the local StoreKit
catalog is copied only into the UI-test bundle, never the distributed app.

## Before accepting real payments

- Owner must complete App Store Connect Business: legal entity/compliance,
  Paid Apps Agreement, banking and tax forms. Owner chose to leave this pending.
- Finish a real sandbox/TestFlight purchase, restoration, expiration, refund,
  cancellation, Ask to Buy and billing-retry/grace-period pass before release.
- The actual paywall review screenshot is uploaded. Attach this first subscription
  to an app version containing purchases; submit both for Apple review.
- Existing TestFlight 1.0 (2) does not contain subscription functionality.
- Do not present this implementation as approved or accepting live payments.

## Reproduce tests

`swiftc -O -parse-as-library CloudChess/PuzzleAllowance.swift scripts/test_puzzle_allowance.swift -o /tmp/cloudchess-allowance && /tmp/cloudchess-allowance`

The shared `CloudChess-StoreKit` scheme and `CloudChess.xctestplan` exercise the
free quota, saved-puzzle resume, purchase/restoration/expiry, pending approval and
refund. The production `CloudChess` scheme has no StoreKit test configuration.
On iOS 26.5, SKTestSession currently reports SKInternalErrorDomain code 3 for
configuration mutations. Native Xcode Run initializes the product catalog, but
this does not repair the broken test-session controls. This platform limitation
must not be mistaken for successful end-to-end payment verification.

Evidence and final verification results are retained under reports/monetization.

## Verification, October 7, 2026

- Rolling-allowance oracle: 101,012 assertions passed (expiry boundaries,
  duplicate delivery, paid access, backward clock, serialization and 50,000
  deterministic mixed operations).
- Focused selector: 301,562 checks over 100,000 draws, all 25 board shapes,
  both puzzle families and four skill levels passed.
- Candidate proof regression: 15,031 checks, 39 positions with alternative
  solutions and all 25 board shapes passed.
- Independent chess rules/proofs: 273,072 checks, 26,207 certified variations,
  1,146 alternative branches; 128 independent Python proofs passed.
- Native three-puzzle, fourth-paywall and same-puzzle relaunch UI test passed.
  Compact-phone largest-text paywall dismissal and offline legal-panel tests
  also passed.
- Signed Release iPhone build succeeded; codesign validation passed. The
  distributed bundle contains neither the test catalog nor debug quota flags.
- Product loading and the displayed $7.99 monthly offer verified in Xcode.
  Two lifecycle UI tests fail while Apple's simulator reports
  SKInternalErrorDomain=3 on SKTestSession mutations; manual test purchase also
  stalls in Apple's local payment service. These are **not passing payment tests**.
  Re-run on a working StoreKit runtime and real sandbox before release.
- Final compact-phone return/resume test passed after updating the former
  fresh-puzzle expectation. Largest-text paywall re-tested and visually checked
  after fixing truncated action labels. Signed Release 1.0 (3) installed and
  launched on the paired iPhone, preserving its existing game data.
