# Tortu

A macOS application that finds what quietly accumulates on a disk, measures it
honestly, and says how much of it is safe to remove.

Tortu grew out of a real problem: a 228 GB development machine that filled up
seven times in two months. Each clean-up returned tens of gigabytes and none of
them lasted. The interesting part was never which files were large — it was how
fast they came back, and which single tool was responsible.

## What makes it different

Most disk tools take a snapshot. Tortu keeps a series, so it can answer the
question a snapshot cannot: *Xcode's DerivedData went from nothing to 10 GB in
eighteen days.* That is the number that tells you where to look.

It also measures correctly, which is harder than it sounds:

- **Walks stop at filesystem boundaries.** `du` once reported 22 GB inside
  `~/Library/Developer/CoreDevice/DeviceFS`. That directory is a `devicefs`
  mount showing a paired iPhone; it occupies 8 KB on the Mac.
- **Boundaries are decided by `st_dev`, not the mount table.** macOS joins the
  System and Data volumes of an APFS volume group with firmlinks and lists both
  as mounts, yet they are one filesystem. Trusting the mount table would skip
  the user's entire home directory.
- **Sizes come from allocated blocks,** because that is what the volume gives
  back. Results are then verified against a real volume reading rather than
  reported from the estimate.

## Building

Requires Xcode 16 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Tortu.xcodeproj
```

The project file is generated and is not checked in. The Swift packages under
`Packages/` build and test on their own:

```sh
for package in Packages/*/; do (cd "$package" && swift test); done
```

## Layout

| Package | Responsibility |
| --- | --- |
| `ScanCore` | Filesystem walking, mount boundaries, size accounting |
| `RulesEngine` | Rule definitions, matching, candidate selection |
| `SafetyKit` | Running-process guards and protected paths |
| `CleanerKit` | Deletion execution and reporting |
| `HelperProtocol` | The XPC contract shared with the privileged helper |
| `Entitlements` | Capability gating for the paid build |

## Rules are data

A cleaner is a JSON file, not Swift code, so a contribution does not require
touching the app:

```json
{
  "id": "flutter.build-cache",
  "name": { "en": "Flutter build cache", "tr": "Flutter build önbelleği" },
  "category": "developer",
  "paths": ["~/**/.dart_tool/flutter_build/*"],
  "strategy": { "keepNewest": 2 },
  "requiresRoot": false,
  "regrows": true,
  "cost": { "en": "The next build compiles from scratch",
            "tr": "Sonraki build sıfırdan derlenir" }
}
```

`keepNewest` exists because Flutter creates one build directory per
configuration and never removes the old ones. One project had accumulated 95 of
them. Deleting all of them forces a full rebuild; keeping the newest two
reclaims nearly everything.

## Open core

The application is open source under Apache-2.0. A separate paid build adds
history charts, background monitoring, scheduled profiles, a duplicate finder
and an application uninstaller.

Nothing security-critical is sold. The privileged helper and every rule that
deletes a file stay in the free, open build, so the code that runs as root can
be read by anyone. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Status

Early. `M0` is complete: package layout, menu bar, window shell, settings,
history store and localisation. The scanner lands in `M1`.

## Licence

Apache License 2.0. See [LICENSE](LICENSE).
