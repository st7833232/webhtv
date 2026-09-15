# IOS-POC-1E: imported configuration persistence

## Recovery anchor

- Objective: after importing the current `wang-movie.json`, restore its iOS-supported CMS sites and the last selected site key on relaunch without requiring another file pick.
- Acceptance: valid imports replace the saved configuration atomically; relaunch restores it and the selected key when still present; missing/corrupt saved data shows the import path and an actionable error; failed imports do not replace a valid saved copy. No Android or `WebHTVCore` edits.
- Branch/base: `ios-poc`, `7e6cb0e7e167d2e736262e88177dac5d891001d8`; protected dirty paths: none. Task guard: `IOS-POC-1E`, scope is this file, the existing iOS handoff, and `ios/WebHTVApp/Sources/WebHTVApp.swift`.
- Plan: approved by the user's `繼續` after POC-1E was recommended. Research, narrow SwiftUI implementation, positive simulator lifecycle verification, and local closure are complete. Rollback anchor: commit `3d715f04aaab607499b3d52982f6aa3858c1b3f6`. Exactly one next action: retain the negative/provider-specific test limits below for a future targeted validation task if needed; do not repeat POC-1E implementation.

## Research question and decision

How should an imported, user-managed JSON configuration and one selected site key survive iOS app relaunch without retaining access to the external Files URL or adding a database?

### Confirmed facts

1. The current `ConfigView.load(_:)` reads the security-scoped URL, decodes sites into `@State`, and resets selection to the first site. No file write or restore caller exists (`ios/WebHTVApp/Sources/WebHTVApp.swift`, base revision above). The selected site key is `Site.id == Site.key` (`ios/Sources/WebHTVCore/WebHTVConfig.swift`).
2. Apple [fileImporter documentation](https://developer.apple.com/documentation/swiftui/view/fileimporter%28ispresented%3Aallowedcontenttypes%3Aoncompletion%3A%29) says the returned URL is security-scoped and access must be started then stopped. Copying the validated bytes while access is active avoids keeping an external bookmark. Grade A, official SwiftUI Markdown read 2026-09-15; caveat: importer providers can fail or deny access.
3. Apple [file-system guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively) recommends Application Support for long-lived files managed by the app but not user-visible, while Caches/Temporary can be purged. [FileManager directory lookup](https://developer.apple.com/documentation/foundation/filemanager/url%28for%3Ain%3Aappropriatefor%3Acreate%3A%29) can locate and create that directory. Grade A, official Foundation Markdown read 2026-09-15; caveat: the small JSON may be included in device backup, which is appropriate for a user-imported configuration.
4. Apple [atomic data writing](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic) writes an auxiliary file before replacing the target, and [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults/set%28_%3Aforkey%3A%29-8ab6d) stores property-list types such as one string. Grade A, official Foundation Markdown read 2026-09-15; caveat: an atomic file replacement is not a transaction with the independent defaults key, so selection must be validated against decoded sites at launch.
5. Android `VodConfig.setHome` persists the site's key through `Config.save()` (`app/src/main/java/com/fongmi/android/tv/api/config/VodConfig.java:312`, `app/src/main/java/com/fongmi/android/tv/bean/Config.java:257`). Grade B, local 5.6.0 upstream source read 2026-09-15; it is behavioral parity evidence, not an iOS storage design to copy.

### Inferences and unknowns

- Inference: one validated JSON file plus one key is enough; a new SwiftData/Room-like database would add ownership and migration complexity without a second entity. A removed site key should fall back to the first supported site.
- Unknown: third-party Files providers may return a security-scope failure or read error; the app must surface it. This POC does not test every provider or all type-3/type-4 Recha sources.

### Alternatives and implications

- No change: no write, but every restart repeats file selection and returns to the first site. Correctness of existing CMS remains, usability target fails.
- Unmodified Android approach: retain a config URL and Room record. This is not reachable in iOS without an external security bookmark and a database; more lifecycle/security maintenance for this single JSON.
- Selected WebHTV adaptation: decode first, then `Data.write(options: .atomic)` into Application Support, assign state only after write succeeds, and keep one site key in `UserDefaults`. On launch, decode the owned file and validate the key against the current sites. This preserves CMS/API compatibility, avoids new dependencies and repeated provider access, costs one small read per launch, and has no ABI/native/package-size change. It is reversible by the task commit and requires one build plus a simulator import/relaunch scenario.

### Evidence-class coverage

- Exact upstream source/tests: current iOS `ConfigView`, `Site` and supplied-config/live-CMS tests; Android `VodConfig`/`Config` for selected-key behavior.
- Official platform/specifications: the four Apple Foundation/SwiftUI pages cited above.
- Upstream PRs/issues/reverts: inapplicable to this platform-local persistence slice; no upstream merge candidate or dependency revision is being adopted.
- Mature related-project code: the existing Android implementation is the relevant product behavior reference, but its Room architecture is rejected for iOS.
- Papers/blogs/benchmarks/field reports: inapplicable to one 125 KB local configuration file; no performance claim beyond the single bounded read is used.

## Verification and closure

- Xcode 26.3 iPhone 17 Pro Simulator Debug build passed with code signing disabled on 2026-09-15. No Android or `WebHTVCore` change was made.
- The current Recha `wang-movie.json` was imported through iOS Files. The app-owned Application Support file has exactly the same 125,864 bytes and SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168` as the selected input. The original Files-provider JSON was left untouched.
- A non-first site, `vod_360`, was selected. Simulator preferences stored `selectedSiteKey = vod_360`; after terminating and relaunching the app, its home showed `360` selected with the imported source list. The source's own TLS failure is separate from persistence and was not bypassed.
- Negative-path limitation: an invalid JSON file was staged in the simulator Files provider, but the settings list could not be scrolled to its re-import row through the available UI control. That UI scenario was not run. The implementation decodes and rejects an empty supported-site list before the atomic file write, so this path cannot replace the existing valid file; malformed JSON also throws before that write. Provider-specific permission failures remain untested and surface an error in code.
- Final-diff Ponytail review: the change uses `FileManager`, `Data.write(.atomic)`, and one `UserDefaults` string; no database, bookmark, dependency, parallel state store, or Android change. Committed locally as `3d715f04aaab607499b3d52982f6aa3858c1b3f6` with annotated tag `recovery/IOS-POC-1E/20260915144034-3d715f04aaab`; no push was authorized.
