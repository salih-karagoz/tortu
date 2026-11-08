# Releasing Tortu

Tortu is distributed as a signed, notarised DMG. It is not on the App Store:
the sandbox the store requires would stop the app reaching the cache
directories it exists to measure, and would stop it installing the privileged
helper.

## What you need once

A **Developer ID Application** certificate in the login keychain. This is not
the same certificate used to ship to the App Store, and having one does not
give you the other.

```sh
security find-identity -v -p codesigning   # must list "Developer ID Application: …"
```

Keep a `.p12` backup of it somewhere other than this machine. Apple issues the
certificate but never stores the private key; losing the key makes the
certificate useless and the replacements are rate-limited.

A **notarytool keychain profile**, created from an App Store Connect API key:

```sh
xcrun notarytool store-credentials "TortuNotary" \
  --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer <issuer-uuid>
```

The issuer id is on App Store Connect under Users and Access → Integrations.
Using an API key avoids typing an Apple ID password into a build script.

## Cutting a release

```sh
./scripts/release.sh
```

The script archives, exports, notarises, packages and verifies, and prints the
SHA-256 of the DMG. Set `TORTU_NOTARY_PROFILE` to use a profile other than
`TortuNotary`.

## Things that will bite you

**Build, not archive.** `xcodebuild build` leaves
`com.apple.security.get-task-allow` in the binary and the notary service
rejects it outright. The script archives and exports instead, and fails early
if the entitlement survives.

**The app's bundle identifier must be in `Info.plist`.** Setting
`PRODUCT_BUNDLE_IDENTIFIER` alone is not enough; without
`CFBundleIdentifier` in the plist the bundle takes its identifier from the
product name. Archiving then fails with "Archive Missing Bundle Identifier",
and worse, the helper's XPC requirement never matches.

**The helper needs its identifier compiled in.** A command-line tool has no
`Info.plist` file, so `CREATE_INFOPLIST_SECTION_IN_BINARY` embeds one.
`SMAppService` matches the launchd label against it.

**The signing team is not always the development team.** The Developer ID
certificate may belong to a different team than the Apple Development
certificate on the same machine. `TortuHelper/HelperIdentity.swift` pins the
signing team; a mismatch there produces an app that installs its helper and is
then refused by it.

**Staple the app, not only the image.** The script notarises the app first and
staples it before building the DMG, so a copy dragged out of the image still
validates offline.
