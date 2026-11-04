# Safety and footprint audit

Base: e4cf57f. Preserve existing work. No live power changes or publication.
Power worker owns model, sleep seam and tests. Runner owns command lifecycle.
Parser owns framing. Session worker owns retention. Lead owns docs, adapters
and final checks. Independent QA and principal review throughout the work.

User contract: at battery floor, release assertions, restore the owned lid hold,
request Mac sleep. Bound retries. Unknown power releases holds without sleep.
Use a local activity bridge and timed manual hold for apps without task events.
Keep interfaces stable and source ownership separate. All power tests use fakes.

Verify RED then GREEN, full Swift tests, release build and script tests.
Use an independent read-only Claude Code Opus review with Superpowers.
Record token measurements, evidence and limits in docs/audit-2026-11-04.md.
