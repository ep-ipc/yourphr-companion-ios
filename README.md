# YourPHR Companion (iOS companion)

The iOS companion for YourPHR. The goal is to have a mobile app that allows equivalent features to the web app in a mobile context, with additional features like health metrics syncing. 

This current iteration implements health metrics syncing only.

## Build & Setup

### 1. Build XCode project

HealthKit requires a **physical iPhone** and a signing team. The Simulator can pair (paste the API address and the setup code) but cannot read HealthKit.

```bash
# from this directory
brew install xcodegen          # once
xcodegen generate
open YourPHRCompanion.xcodeproj
```

In Xcode: select the **YourPHRCompanion** target → Signing & Capabilities → choose your Personal Team. The bundle id is `com.iplusconnect.companion`.

### 2. Pair with YourPHR

Three switches in Admin → Configuration need to be set to True (they are False by default):

- `yourphr.devices.enabled`
- `yourphr.health.enabled`
- `yourphr.health.device-intake.enabled`

1. In YourPHR, open **Settings → Connected devices**, name this phone, choose how long to allow it (up to `yourphr.devices.grant-max-days`, 30 by default), and confirm with the password. Restart YourPHR for the settings to take effect.

2. On the phone: scan the QR, open the link, **or** paste the site address and the setup code. A pasted origin without `/api` gets that suffix.


## Development Notes

The access token lasts `yourphr.devices.key-ttl-hours` (24 by default). It is refreshed with `POST {server}/device/token` before a sync when it is near expiry, and once after an upload returns 401. A refresh token is sent only once. 401 on refresh means the permission ended (removed, expired, a password change, or sign-out everywhere): add the device again. 403 with the pause message means nothing was uploaded for `yourphr.devices.inactive-after-days` (90 by default): resume it in Settings → Connected devices. The same refresh token works again after a resume. Uploading counts as activity. Refreshing does not.

Samples go to `POST {server}/secure/health/samples` as FHIR Observations, with `device.device_id` and no `source_id`. Sleep stages are LOINC `93828-2`, `93830-8`, `93831-6`, and `93829-0` (in bed and unspecified stay on the phone). Oxygen posts `59408-5` then `2708-6`. Timestamps carry the sample’s offset. The phone posts steps as one Observation per local day (`steps-YYYY-MM-DD`), the deduplicated Apple Health total. YourPHR keeps those raw samples and writes a daily summary into the record. Steps from the phone and the watch on the same local day keep the larger total. Sleep keeps one source for that day (more stage samples, then the longer total) and does not add the other; each kept stage is one Observation of hours. Heart rate, oxygen, and heart-rate variability average every sample across sources. Blood pressure, weight, and temperature stay their own Observations. A sample removed in Apple Health is posted again as `entered-in-error` with the same identifier and no new time. A sync bookmark longer than 1024 characters stays on the phone; the samples in that page still upload. A 404 on the claim means Connected devices is off. A 404 on the upload or on sync-state means Health is off. A 403 on the upload that names device intake means `yourphr.health.device-intake.enabled` is off. A 429 waits and retries the same page.

Local HTTP on the LAN is allowed via `NSAllowsLocalNetworking`. The phone and the YourPHR host must be on the same Wi-Fi. Safari can open that address without Local Network permission; this app cannot. The first claim publishes `_yourphr._tcp` (listed in `NSBonjourServices`) so iOS shows the Local Network prompt. YourPHR Companion is absent from Settings → Privacy & Security → Local Network until that prompt has been shown. Denying it fails the claim. iOS reports that block as the internet being offline.

On the Simulator, pair, then use Continue without HealthKit on the Apple Health prompt. Sync now stays disabled until a phone with HealthKit is paired.

## What "every 5 minutes" actually means

iOS will not wake a suspended app on a timer. The 5-minute interval is a **foreground** promise:

| Situation | What happens |
|---|---|
| App open | A 5-minute timer triggers a sync |
| App not open, new HealthKit samples | `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` wakes the app |
| App not open, no new samples | `BGAppRefreshTask` is requested every 5 minutes; iOS may delay it by hours |
| Phone locked | The observer still fires, but reading the HealthKit store often fails. The app marks a pending sync and retries on unlock / next foreground / next refresh |

A background wake has ~30 seconds. Large first-run backfill (default 30 days) is a foreground job with a progress label.

## Verify a push

After a successful Sync Now, sign in on the site and open Health. The page shows the daily summaries and which source each one came from. The device key cannot read samples back.

## Tests

In Xcode: Product → Test, or:

```bash
xcodebuild -scheme YourPHRCompanion -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Those tests do not need HealthKit data: they cover JSON shape, units, batching, QR parsing, and anchor round-trip.
