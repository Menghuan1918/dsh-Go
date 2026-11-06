# On-device XCUITest runner for iOS phone control

Status: design/reference note. This document compares the available iOS phone-control
approaches, records the direct-launched XCUITest runner experiment, and lists its risks. It does
not include the implementation or signing changes.

## Summary

This is a design/reference proposal for restoring **element-tree phone control on iOS** without a Mac at runtime, keeping screenshots as a fallback.

The current `dsh-Go` iOS phone path has two modes:

1. The old Mac-hosted `PhoneRunnerUITests` (XCUITest) with a full element tree, but it needs a Mac host, an App Group, and a paid Apple team.
2. The CoreDevice self-runner (screenshots + HID, no App Group) which works without a Mac but has **no element tree**, no reliable secure-field detection, and only coordinate taps.

This proposal keeps the old XCUITest test bundle, installs it once as a `.xctrunner` app, and has the app launch it directly with `LSApplicationWorkspace`. XCTest then runs `PhoneRunnerUITests.testServe` as a normal app, and DSH Go talks to its loopback HTTP server. No Mac, no `testmanagerd`, and no App Group are involved at runtime.

## Approach comparison

| Approach | Element tree | Secure-field refusal | Mac at runtime | App Group / paid team | Notes |
|---|---|---|---|---|---|
| Mac-hosted XCUITest (`phone-runner.sh`) | Yes | Yes | Yes | Yes | Existing fallback; full XCUI tree |
| CoreDevice self-runner (screenshots + HID) | No | No | No | No | Current no-Mac mode; `screen`/coordinates only |
| AX audit service (`axAuditDaemon.remoteserver`) | Focus-based, not a full tree | No traits | No | No | DTX; `perform_press` needs `task_for_pid-allow` |
| WDA | Yes | Yes | Usually host to launch/keep alive | Runner signing | Mature, but another runner and HTTP layer |
| **Proposed: direct-launched XCUITest runner** | **Yes** | **Yes** | **No** | **No** | One-time runner install; screenshot fallback |

## Proposed flow

1. Build/install the existing UI test runner once:
   - Visible name: `io.github.menghuan1918.dshgo`
   - Bundle id: `io.github.menghuan1918.dshgo.runner.xctrunner` (the exact app id would collide with the main app; `.xctrunner` is the test-runner suffix)
2. On the first phone tool call, DSH Go brings the runner foreground with `LSApplicationWorkspace`.
3. XCTest starts `PhoneRunnerUITests.testServe` without a `testmanagerd` host; its `PhoneServer` binds loopback.
4. DSH Go calls `127.0.0.1:<port>/rpc` with a bearer token.
5. `screen` returns the XCUI element tree (types, labels, values, frames, screen id); `screen(image:true)` still attaches a screenshot; `tap` by element id, `type` with secure-field refusal, `collect`, `scroll`, `key` and `open` are the original phone tools.
6. If the runner is missing or cannot start, fall back to the CoreDevice screenshot/HID self-runner.

## Evidence

Tested on iPhone 18 Pro Max, iOS 27.3, Xcode 27.2:

- `screen` → element tree for `com.apple.springboard`.
- `open` Settings → element tree for `com.apple.Preferences`.
- `screen` after switching apps → still served by the runner; element tree for Settings.
- `apps` → third-party app list; Apple/system entries filtered; a query still searches them.
- `tap` by `screen` + id → returned a new screen.
- `screen(image:true)` → 80–300 KB PNG.

Host-side note: `xcodebuild test` on this device/Xcode combination exits with `The test runner exited with code 74 before establishing connection`. Directly launching the same installed runner works, which is why this proposal avoids `testmanagerd`.

## XCTest risks / limitations

- **Unsupported launch path.** Launching a `.xctrunner` app directly and using `LSApplicationWorkspace` is not a supported/public API contract. It can break on an iOS or Xcode update.
- **Runner lifecycle.** Without `testmanagerd`, the runner is a normal app. In testing it stayed alive after another app came to the foreground, but long-running background behavior is not guaranteed; iOS may suspend it. The CoreDevice fallback exists for this case.
- **Provisioning/installation.** The runner is a separate app and must be installed once. A free/personal team profile expires and needs reinstall; the app cannot install it by itself.
- **App enumeration.** The runner sandbox returns an empty `LSApplicationWorkspace` list on iOS 27, so `apps` falls back to the CoreDevice self-runner (pairing + LocalDevVPN). Without that fallback the element tree still works but `apps` is empty.
- **Security surface.** The current prototype uses a fixed loopback port and bearer token because the foreground launch cannot carry argv. A local app that knows the token could drive the runner. Secure fields are refused by the runner, but non-secure control is still possible; this is a personal, sideloaded tool.
- **App Store.** This is developer/sideload-only; direct XCTest runner launch and private app enumeration would not be acceptable for App Store distribution.
- **Secure-field detection is trait-based.** Fields that ask for passwords/codes without a secure trait (or with unusual labels) still depend on the label heuristic and the model/handoff instruction.
- **Version coupling.** XCTest/XCUIAutomation frameworks, the developer disk image, and the runner bundle are tied to Xcode/iOS versions. Future updates need a rebuild and reinstall.
- **Fixed naming/bundle.** The runner cannot use the exact main-app bundle id `io.github.menghuan1918.dshgo` because it must coexist with the app. The visible name can be that string; the bundle id uses `.runner.xctrunner`.

## Open questions

- Is an optional iOS self-runner worth carrying upstream, given the private launch path and the one-time runner install?
- Separate runner app vs. in-process XCTest (TouchSynthesis-style) — the latter keeps the main app identity but is much more private-API-heavy.
- Should a per-launch random token be passed through a URL scheme or app-service args instead of a fixed token?
- How should the existing 30-minute foreground grant and the pending notification-action approval interact with this mode?

I can provide the implementation branch/patch for reference if useful. This issue is for design discussion; the upstream repository's stated policy is that it does not accept external PRs, so this is not a request to merge.
