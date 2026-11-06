# Study Desk resource management

The resource changes target three source-confirmed problems: unbounded retained
chunks, serialization on the UI isolate, and asynchronous cache results surviving
invalidation. They preserve the existing revision-based disk cache and native
offloading of large chunking jobs.

## Cache and lifetime policy

`StudyRagIndex` retains at most 24 notes and 8 MiB of estimated chunk data. Both
limits are configurable in its constructor. Hits refresh LRU order. A note larger
than the byte budget is returned normally and can be stored on disk, but does not
evict smaller hot entries just to enter memory. The byte counter includes text,
line objects, list slots and stroke references; it is an estimate, not a bound on
the process heap, native images, or GPU memory.

Concurrent requests for the same note revision share a build. An older build
cannot replace a newer revision. Memory pressure and pruning advance a generation,
so already pending work may finish for its caller without refilling an invalidated
cache. Index builds await their optional disk write rather than launching detached
serialization jobs for every note.

Only one warm-up pass continues when sources change. It skips disabled sources,
prepares at most the memory-cache note capacity, and yields to event processing
between notes. Superseding a pass, disabling/removing sources, creating a chat,
memory pressure, and disposal cancel its pending yield. Already running work is
invalidated rather than described as cancellable.

The whole-note cache still retains at most three notes. Citation resolution keeps
only the needed pages locally for the duration of that answer, so evicting a note
from the shared cache no longer drops citations from an answer citing four or more
notes. Completed futures already retain their loaded content; the duplicate
completed-content map has been removed. Disposal clears retained caches and late
page loads return no result.

## Persistence and native concurrency

For desk history and chunk files, large JSON conversion and model construction run
inside `compute`, including `toJson` and `fromJson`. Smaller payloads stay local to
avoid a worker for every tiny edit. The dispatch threshold is an estimated 8 KiB
for writes and 8,192 encoded characters for reads; tune it using device profiles.
Callbacks are top-level functions receiving plain model data, with profiler labels
`study.readDesk`, `study.writeDesk`, `study.readChunks`, and `study.writeChunks`.

Full snapshot writes retain one active snapshot and only the newest pending
snapshot. All callers in a burst complete after that batch's latest snapshot is
written. Chunk writes serialize independently per note, preventing races on the
same temporary filename. Pruning waits for an active removed-note write before
deleting its destination. Files still use temporary-write-and-rename replacement.
Desk write failures reach callers and a subsequent save can retry. Chunk-cache
failures remain optional cache misses.

No worker pool or thread-per-note scheme is introduced. Ordinary file I/O remains
asynchronous. Flutter `compute` runs on a separate isolate on native platforms;
on web it uses the current event loop. The repository's file stores are native
`dart:io` implementations, and this change makes no web parallelism claim.

## Research

- [Flutter concurrency and isolates](https://docs.flutter.dev/perf/isolates):
  separate substantial CPU work from UI execution; account for message transfer
  and worker lifetime.
- [compute API](https://api.flutter.dev/flutter/foundation/compute.html): native
  versus web behavior, transferable inputs and named profiling spans.
- [Flutter performance practices](https://docs.flutter.dev/perf/best-practices):
  reduce unnecessary work and allocation before introducing concurrency.
- [Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance):
  use profile mode and physical hardware for frame-time conclusions.

## Verification

```powershell
flutter test --no-pub test/features/library/study_desk_test.dart test/features/library/study_desk_redesign_test.dart test/features/library/study_practice_test.dart test/features/library/study_desk
dart analyze lib/features/library/study_desk/study_desk_store.dart lib/features/library/study_desk/study_rag_index.dart lib/features/library/study_desk/study_desk_controller.dart test/features/library/study_desk/study_resources_test.dart integration_test/study_desk_resources_performance_test.dart test_driver/perf_driver.dart
flutter drive --no-dds --no-pub --profile --driver=test_driver/perf_driver.dart --target=integration_test/study_desk_resources_performance_test.dart -d DEVICE
```

The resource suite covers LRU and byte eviction, oversized entries, deduplication,
out-of-order revisions, invalidation during reads, retry after failure, four-note
citation resolution, disposal while loading, large file round trips, burst saves,
overlapping chunk writes, and pruning during a write. Three invalidation/revision
tests failed against the original implementation before passing with the changes.
The combined Study Desk and practice regression run passed 177 tests.

The standalone profile harness compares the previous main-isolate persistence
algorithm with the current store in the same run. It uses 24 chats of 12 messages,
five samples of eight full snapshot writes, and a save/reload validation. It reports
API-call blocking duration, total burst save/reload latency, and gaps in a 4 ms
event-loop heartbeat to `build/study_desk_resource_stats.json`. These synthetic
storage measurements are separate from scrolling FPS and full-app memory trends.

On 2026-11-04, this harness completed on the connected Xiaomi 25097RP43G tablet
(Android 16, ARM64, profile mode, Flutter 3.50.0-1.0.pre-230, Dart 3.15.0 dev).
Both implementations used the same 743,037-character history, one warm-up, and
five measured bursts of eight writes:

| Measurement | Previous algorithm | Current store |
| --- | ---: | ---: |
| Write API blocking, p90 | 3.960 ms | 0.136 ms |
| Burst save and reload, median | 76.181 ms | 25.345 ms |
| Burst save and reload, worst | 94.273 ms | 26.585 ms |
| Event-loop heartbeat gap, worst observed | 29.210 ms | 9.346 ms |

The profile test reported success and saved its result JSON. These are one-device,
same-run synthetic measurements, including isolate startup/transfer and disk I/O.
They do not certify a frame-rate target, cold-start latency, long-session heap
stability, or performance on other devices. The native file-store paths were
tested; web was not profiled. Targeted analysis of the changed Dart files reported
no issues.

The existing transcript-scrolling profile APK built and installed on the connected
Android 16 tablet, but the driver connection closed before producing a completed
trace. That attempt establishes no scrolling or 60/120 Hz result.
