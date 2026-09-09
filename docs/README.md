# Product Requirements Documents

The PRD evolved alongside the build. Each revision is kept rather than
overwritten, because the interesting part is where the plan was wrong and what
the evidence was.

| Version | What changed |
|---|---|
| **v1.1** | Original document. Dual-source: Dexcom Share primary, Apple HealthKit as fallback. |
| **v1.2** | Correctness pass over v1.1. ~50 findings: a linear IOB decay that is clinically wrong, `BGAppRefreshTask` treated as a schedule, a Keychain accessibility class that breaks background operation, and a prediction accuracy target a naive baseline already passes. |
| **v1.3** | Architecture replaced. Apple Health turned out to carry a **documented three-hour delay**, which v1.1 had assumed was 15–30 minutes of write batching and v1.2 had compounded by promoting Health to primary. Direct Bluetooth adopted instead. |
| **v1.4** | Architecture replaced again, this time by hardware. Direct BLE was built and tested: the sensor accepts a connection, holds it ~10 seconds, sends nothing, disconnects. The G7 permits one collecting app per sensor. Share becomes the sole live source. |
| **v1.5** | Build pass — persistence, charting, theming, statistics. Records the decisions that only surface once code meets real data. |
| **v1.6** | Backfill and export. v1 feature-complete. |

## Appendix B

Every revision from v1.2 onward carries a findings log mapping each change to
the evidence that prompted it. Ten sections, roughly ninety findings.

The recurring theme in the later ones is worth stating plainly: **the obvious
implementation compiles, looks correct, and is silently wrong.** A `Date` used
as a deduplication key admits near-miss duplicates that corrupt every statistic
with nothing visibly broken. Downsampling by bucket mean erases the hypo you
most need to see. A midnight-crossing schedule check is false for every minute
of the window it governs. Statistics computed in a SwiftUI view body are
invisible at 39 readings and re-sort 8,600 every second at real volume.

Several of these were caught only because the app was run against real data on
real hardware. None would have been caught by review alone.
