# iOS Screen Time: what we did and what real integration needs

## Short version

Per-app iPhone usage cannot be sent to our server in a hackathon. For the demo:

| Card | Data | Label in the API / dashboard |
|---|---|---|
| Blink rate by Mac app | **Real.** The Mac's frontmost app (`lsappinfo`, polled every 5 s, no permission prompt), joined with the eye samples recorded during each app session | `"mock": false` |
| Mac app usage | **Real**, same source | `"mock": false` |
| iPhone app usage | **Mock.** A fixed sample day in `backend/screentime.py` (`IOS_MOCK`) | `"mock": true`, "MOCK DATA" badge |

The correlation the pitch is about ("you blink 8 times a minute in Xcode versus 17 in
Slack") is measured on the Mac, where the glasses are actually used with a screen.

## Why iOS is hard

Apple's Screen Time API is three frameworks, all built around keeping the data on the device:

- **FamilyControls**: asks the user (or a parent) for authorization. Shipping it needs
  the *Family Controls (Distribution)* entitlement, which Apple grants on request after
  review. Development builds can use it on your own device.
- **DeviceActivity**: schedules monitoring and calls an app extension when usage
  thresholds are crossed (for example "Instagram > 30 min"). You get events, not a usage log.
- **DeviceActivityReport**: the only way to see per-app durations. It runs in a sandboxed
  extension that can draw SwiftUI views for the user but **cannot use the network or
  write anywhere the main app can read**. Apple designed it so usage data cannot leave
  the device.

Apps are also identified by opaque tokens (`ApplicationToken`), not bundle IDs or names.

## What real integration would take (after the hackathon)

1. Native iOS target with the Family Controls entitlement (request it from Apple early,
   since approval takes days to weeks).
2. Request `AuthorizationCenter.shared.requestAuthorization(for: .individual)`.
3. Show per-app usage in a `DeviceActivityReport` extension, *on the phone*, next to
   the glasses' eye metrics. The eye data comes *to* the phone instead of usage data going to the server.
4. For server-side correlation, use DeviceActivity threshold events. The monitor
   extension can store "category X crossed 30 min at time T" in the shared app group,
   and the app can upload those coarse events. That is legal and gives
   time-of-day/category correlation without per-app logs.
5. Without the entitlement, the user can type in their Screen Time totals
   (Settings → Screen Time → See All Activity), or we can import a CSV. The
   `app_usage` table already takes `source = "ios_import"` rows.

## Replacing the mock

`POST`ing an import is not built yet. To swap the mock for real numbers by hand,
edit `IOS_MOCK` in `backend/screentime.py` (app, category, minutes).
