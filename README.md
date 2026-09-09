# GlucoNoir

A dark-mode Dexcom G7 companion app for iOS. Personal use, built for a single
user with Type 1 Diabetes.

The official Dexcom G7 app uses a bright interface that is punishing at 3am,
when glucose checks are most frequent. GlucoNoir reads the same data and
presents it in a true-black, OLED-friendly interface with a Bedside Mode that
shifts everything red to preserve dark adaptation.

## Not a medical device

GlucoNoir **does not alarm**. The official Dexcom G7 app stays installed and
remains the sole source of low and high glucose alerts — it reads the sensor
directly over Bluetooth and depends on neither a network nor a background
scheduler, and it is FDA-cleared for that purpose. This app is not.

## Architecture

| Layer | Source | Latency |
|---|---|---|
| Live readings | Dexcom Share API | ~1–2 minutes |
| Historical backfill | Apple HealthKit | 3 hours (history only) |
| Direct Bluetooth | *ruled out* | see below |

Reading the G7 directly over BLE was implemented and tested against real
hardware. It does not work while the official Dexcom app is installed, and the
official app cannot be removed. The sensor accepts the connection, holds it for
~10 seconds, sends nothing, and disconnects: the G7 permits one collecting
application per sensor. The evidence is recorded in the PRD.

Apple Health carries a documented three-hour delay, so it is used for history
only and is structurally barred from supplying a displayed current value.

## Features

- Live glucose with trend arrow, in mmol/L or mg/dL
- Persistent history that self-heals — the fetch window sizes itself to the gap
  since the last stored reading
- Chart across 3h to 30d, with gap-aware line breaking and extreme-preserving
  downsampling
- Consensus statistics: five-band time-in-range, CV, GMI (gated to 14 days at
  70% coverage)
- Four themes plus Bedside Mode, schedule-driven
- Export to CSV, JSON backup, and Nightscout format; restore is additive

## Build

Requires Xcode 26 and iOS 26.5. Runs on a free Apple personal team — no paid
membership needed, though provisioning expires every 7 days.

```
open GlucoNoir.xcodeproj
```

Sign in with your own Dexcom account (not a follower's) on first launch. Dexcom
Share must be enabled, which requires at least one follower to exist.

## Tests

```
xcodebuild test -scheme GlucoNoir -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

150+ tests covering Share parsing, unit conversion, persistence and migration,
chart data, statistics, theming, export round-trips, and performance at 90-day
data volume.

## Credit

The Dexcom Share protocol details were verified against
[pydexcom](https://github.com/gagebenne/pydexcom). The G7 Bluetooth protocol
investigation drew on [G7SensorKit](https://github.com/LoopKit/G7SensorKit)
(LoopKit, MIT).
