# Releases

The app is distributed by Inetor Oy (team `TTND84D98U`). Signing identity and bundle ID come from the git-ignored `Config/Signing.local.xcconfig`; the repository itself contains only placeholders.

## How to ship a new TestFlight build

1. Bump `CURRENT_PROJECT_VERSION` (must always go up). Bump `MARKETING_VERSION` when the user-facing version changes. Commit and push first, so the build matches a commit.
2. Archive:
   ```sh
   xcodebuild -project CanineCardio.xcodeproj -scheme CanineCardio -configuration Release \
     -destination generic/platform=iOS -archivePath build/CanineCardio.xcarchive \
     -allowProvisioningUpdates MARKETING_VERSION=<x.y.z> CURRENT_PROJECT_VERSION=<n> archive
   ```
3. Export with manual signing: Apple Distribution certificate + App Store profile "CanineCardio App Store", `method app-store-connect`, `signingStyle manual`.
4. Upload: `xcrun altool --upload-app --type ios -f <ipa> --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID`.
5. Wait for the build to reach `VALID`. The internal TestFlight group "Inetor" has access to all builds, so no further step is needed for internal testing.

Release checks:
- `ITSAppUsesNonExemptEncryption = false` and `PrivacyInfo.xcprivacy` must be in the archive.
- DEBUG launch options must be absent from the release binary.
- Test on a physical iPhone with the newest iOS.

## Log

### 2026-11-21: 0.1.0 (1), first TestFlight build
- App Store Connect app "CanineCardio Research", Apple ID 6837692732, bundle `fi.inetor.caninecardio`, SKU `caninecardio`, primary language en-US.
- Built from commit `357464a`. Upload delivery `b9938587-5eae-4328-85d6-466c82b3a759`; processing state `VALID`. Internal TestFlight state `IN_BETA_TESTING`.
- Internal group "Inetor" (2 team members, access to all builds).
- Upload warning 90984: `UIRequiredDeviceCapabilities = accelerometer` is not supported on visionOS, so the app is not offered on Vision Pro. Intended.
- "What to Test" was not set: the API no longer accepts `whatToTest` on `betaBuildLocalizations`. It can be set in the web UI if needed.
- Not done yet:
  - external TestFlight (needs a privacy policy at `inetor.fi/caninecardio/privacy.html` and Beta App Review);
  - App Store submission (planned after the Polar H10 validation; see the review risks in the conversation notes in docs/ROADMAP.md).
