# delphi-rabbitmq-rest-leakwatch

[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Delphi 2009](https://img.shields.io/badge/Delphi-2009-EE1F35)](#requirements-and-folder-layout)
[![Platform: Win32](https://img.shields.io/badge/platform-Win32-0078D6)](#requirements-and-folder-layout)
[![RabbitMQ 4.4 tested](https://img.shields.io/badge/RabbitMQ-4.4%20tested-FF6600?logo=rabbitmq&logoColor=white)](#rabbitmq-setup)
[![Indy 10.6.3](https://img.shields.io/badge/Indy-10.6.3-blue)](https://github.com/IndySockets/Indy)
[![FastMM4: optional](https://img.shields.io/badge/FastMM4-optional-lightgrey)](#memory-manager)

**LeakWatch** is a Delphi 2009 VCL application that watches the memory of
running Delphi processes for leaks. Every instance:

- takes a snapshot of its memory manager statistics every 2 seconds (the
  memory manager built into the RTL, or optionally FastMM4),
- publishes it to RabbitMQ through the management HTTP API (Indy `TIdHTTP`),
- receives the snapshots of **all** running instances, on one or more machines,
- runs a leak detector per instance and shows warnings with the AppId of the
  leaking instance,
- and contains a leak generator, so you can see the detector at work: Mode A
  churns memory without leaking, Mode B leaks.

It is a demo and a test bed for leak heuristics, not a production monitoring
system (see [Known limitations](#known-limitations)). For the bare management
API calls, see the companion project
[delphi-rabbitmq-rest-starter](https://github.com/michaelJustin/delphi-rabbitmq-rest-starter).

## Contents

- [Architecture](#architecture)
- [Why a fanout exchange and not a stream](#why-a-fanout-exchange-and-not-a-stream)
- [Requirements and folder layout](#requirements-and-folder-layout)
- [Building](#building)
- [RabbitMQ setup](#rabbitmq-setup)
- [Running](#running)
- [Configuration](#configuration)
- [Multiple instances and the acceptance test](#multiple-instances-and-the-acceptance-test)
- [The leak detector](#the-leak-detector)
- [Detector tuning guide](#detector-tuning-guide)
- [Tests](#tests)
- [Known limitations](#known-limitations)
- [Licence](#licence)

## Architecture

```
 LeakWatch process (one per instance)                         RabbitMQ (management plugin, :15672)
 +---------------------------------------------------------+
 |  TLeakThread ----> objects on the heap (Mode A / B)     |
 |                                                         |
 |  TSnapshotThread                                        |    fanout exchange
 |    TMemStats.Capture            -> uSnapshotJson -------------> leakwatch.snapshots
 |    ISnapshotTransport.Publish   (own TIdHTTP)  POST .../publish     |   |   |
 |                                                         |           v   v   v  one classic queue
 |  TConsumerThread                                        |    leakwatch.<InstanceId> per instance
 |    ISnapshotTransport.Poll      (own TIdHTTP)  POST .../get  <------+
 |    -> TSnapshotStore (ring buffer per instance)         |
 |    -> TLeakDetector per instance -> warnings, event log |
 |                                                         |
 |  uAppState (log queue, warnings, status)                |
 |    | PostMessage(WM_APP+1), no data in the message      |
 |    v                                                    |
 |  fMain (VCL): grid, chart, warnings, log, tray icon     |
 +---------------------------------------------------------+
```

| Unit | Purpose |
| --- | --- |
| `uSnapshot` | Shared record types (`TMemSnapshot`, `TSample`, `TLeakLevel`), UTC and ISO 8601 helpers |
| `uMemStats` | The only unit that knows the memory manager: `TMemStats.Capture` |
| `uSnapshotJson` | Snapshot to and from JSON (schema version 1) with JsonDataObjects |
| `uTransport` | `ISnapshotTransport` (`Declare`, `Publish`, `Poll`), broker settings, error classes |
| `uTransportRabbitMq` | The management HTTP API implementation with `TIdHTTP` |
| `uSnapshotStore` | Thread-safe store, one pre-allocated ring buffer per InstanceId |
| `uLeakDetector` | Heuristics, combination and hysteresis; no VCL, Indy or memory manager |
| `uSnapshotThread`, `uConsumerThread`, `uLeakThread` | The three worker threads (`uWorkerThread` is their base class) |
| `uAppState` | State shared between threads and UI: bounded log, capped warnings list, status |
| `uConfig` | INI file and command line |
| `uEventLog` | Detector event log for scripted runs |
| `fMain` | Main form, built in code (no `.dfm`) |

Threads never pass data to the UI inside window messages. They write into the
thread-safe objects of `uAppState` and the store and post a wake-up message;
the UI then reads what it needs. Each network thread owns its own `TIdHTTP`,
since `TIdHTTP` is not thread-safe.

## Why a fanout exchange and not a stream

A stream would be the natural fit for "every instance reads every snapshot",
but RabbitMQ streams are read with the binary stream protocol (port 5552) or
AMQP consumers with an offset. The management HTTP API only has monitoring
endpoints for streams (`/api/stream/...`), no endpoint to read stream messages
or set an offset, and `/get` (basic.get) does not work on stream queues.

So LeakWatch uses a **fanout exchange** `leakwatch.snapshots` and **one classic
queue per running instance**, `leakwatch.<InstanceId>`, bound to it. Every
instance receives every snapshot, including its own.

The queue is declared with `"durable":true` and these arguments:

| Argument | Value | Why |
| --- | --- | --- |
| `x-queue-type` | `classic` | `/get` works on classic queues |
| `x-expires` | 300000 (5 min) | the queue of a stopped instance disappears by itself |
| `x-message-ttl` | 600000 (10 min) | old snapshots are useless |
| `x-max-length` | 5000 | bounds a queue whose instance stopped polling |

Durable, because non-durable non-exclusive queues are deprecated in RabbitMQ
4.x. If the queue expired during a long disconnect, the next `/get` returns
404 and LeakWatch declares it again.

**The HTTP API is not meant for this in production.** RabbitMQ documents
publishing over HTTP as inefficient and `/get` as a tool for development and
troubleshooting. At one snapshot every few seconds per instance this is
acceptable for a tool like LeakWatch. For production, use a native messaging
protocol instead; `ISnapshotTransport` exists so that a different client can
be plugged in:

- **STOMP**: the [Habari STOMP Client](https://habarisoft.com) libraries
  (commercial, Delphi and Free Pascal) keep one persistent TCP connection to
  RabbitMQ's STOMP plugin (`rabbitmq_stomp`, port 61613). The broker pushes
  messages to subscribers, so there is no polling, and they support
  client-side acknowledgements, transactions and heartbeating. A STOMP
  subscription to `/exchange/leakwatch.snapshots` gives every instance its
  own queue on the fanout exchange, as here.
- **AMQP 0-9-1** (port 5672) or the **stream protocol** (port 5552).

## Requirements and folder layout

- Delphi 2009 (Win32). Other Delphi versions are not tested.
- [Indy](https://github.com/IndySockets/Indy) 10.6.3, compiled from source.
  The Indy that ships with Delphi 2009 is **not** used.
- [JsonDataObjects](https://github.com/ahausladen/JsonDataObjects) (MIT).
- Optional: FastMM4 4.993, included in `third_party/FastMM4` (see
  [Memory manager](#memory-manager)).
- RabbitMQ with the management plugin, tested with RabbitMQ 4.4.0 on Windows.

Clone Indy and JsonDataObjects **next to** this repository:

```
<some folder>\
  delphi-rabbitmq-rest-leakwatch\   this repository
  Indy\Lib\{Core,Protocols,System}
  JsonDataObjects\Source
```

```
git clone https://github.com/michaelJustin/delphi-rabbitmq-rest-leakwatch.git
git clone https://github.com/IndySockets/Indy.git
git clone https://github.com/ahausladen/JsonDataObjects.git
```

## Building

**IDE:** open `LeakWatch.groupproj` (the application and the test project) and
build. The projects reference the sibling folders with relative paths.

If the IDE reports *"Unit X was compiled with a different version of
IdGlobal"*, the Indy bundled with Delphi 2009 (`$(BDS)\lib\Indy10`) is on the
IDE library path. Remove it there, or make sure it comes after the project's
search path.

**Command line:**

```
build.cmd                  builds build\LeakWatch.exe
test\run-tests.cmd         builds and runs the unit tests
```

Both use `dcc32.exe` of Delphi 2009 at its default location. Set `BDS`, `INDY`
or `JDO` if your folders differ (see the comments in `build.cmd`).

**MSBuild:**

```
call "C:\Program Files (x86)\CodeGear\RAD Studio\6.0\bin\rsvars.bat"
msbuild LeakWatch.groupproj /t:Build /p:Config=Debug
```

### Memory manager

By default LeakWatch uses the memory manager built into the RTL (since
Delphi 2006 a trimmed-down FastMM4) and reads its statistics with
`System.GetMemoryManagerState`. Its leak report at exit works without any
configuration.

To use **FastMM4 4.993** from `third_party/FastMM4` instead, define
`LEAKWATCH_FASTMM4`:

- IDE: *Project > Options > Directories/Conditionals > Conditional defines*,
  for both projects;
- command line: `set LEAKWATCH_FASTMM4=1` before `build.cmd` or
  `test\run-tests.cmd`.

`FastMM4` then becomes the first unit of the `.dpr` and `uMemStats` queries
`FastMM4.GetMemoryManagerState`. Use it if you want FastMM4's FullDebugMode
(call stacks for leaks) or its newer code. Three things to know, which are
handled in this repository:

- `System` declares its own `TMemoryManagerState` and
  `GetMemoryManagerState` for the built-in manager (55 small block types,
  FastMM4 4.993 has 56). With FastMM4 installed those report on the unused
  built-in manager, so `uMemStats` qualifies every name with `FastMM4.`.
- `FastMM4.pas` includes `FastMM4Options.inc` from its own folder first,
  even when `-I` points elsewhere. That is why FastMM4 is vendored with a
  project-specific options file instead of being a git submodule (see
  [third_party/FastMM4/README.md](third_party/FastMM4/README.md)).
- With its default options, FastMM4 reports leaks only under the IDE
  debugger. The vendored options switch that off and let
  `ReportMemoryLeaksOnShutdown` control the report.

The log shows which memory manager is in use at start-up.

### Warnings

The project's own units compile without warnings. The Indy sources produce
three warnings with Delphi 2009, which are expected:

- W1035 `TIdSocketListWindows.GetItem` (`IdStackWindows.pas`)
- W1035 `TIdIOHandler.WriteFile` (`IdIOHandler.pas`)
- W1035 `TCustomSSPIConnectionContext.UpdateAndGenerateReply` (`IdAuthenticationSSPI.pas`)

## RabbitMQ setup

Install RabbitMQ (for example as a Windows service) and enable the management
plugin, then restart the broker:

```
rabbitmq-plugins enable rabbitmq_management
```

The management API is then at `http://localhost:15672`. The user `guest`
(password `guest`) **only works from localhost**. To run LeakWatch on several
machines, create a user on the broker machine, for example:

```
rabbitmqctl add_user leakwatch <password>
rabbitmqctl set_permissions -p / leakwatch "^leakwatch\..*" "^leakwatch\..*" "^leakwatch\..*"
rabbitmqctl set_user_tags leakwatch management
```

LeakWatch needs to configure, write and read the `leakwatch.*` exchange and
queues, and the `management` tag to use the HTTP API.

## Running

Start `build\LeakWatch.exe`, check the broker settings at the top and click
**Connect**. The lamp turns green when both the publisher and the consumer
work. Pick a generator mode on the left and click **Start**.

- The grid lists every instance that sends snapshots, with its last values,
  its leak level and its state (live, STALE, duplicate AppId, this instance).
- The chart shows the allocated bytes of the selected instance.
- Warnings (level changes) appear in the list at the bottom and as a tray
  balloon. The tray icon is green, orange or red for the highest level of all
  instances.
- **Report leaks at exit**: when set, the objects the generator still holds
  are left allocated on exit, and the memory manager shows its leak report
  (a message box) when the process ends. When cleared, everything is freed and no report
  is shown.

### Identity: InstanceId and AppId

- **InstanceId** = `<hostname>-<pid>`, always generated and unique per
  running process. It names the queue and identifies the series.
- **AppId** is a display label: from `-id=...`, else from the INI file, else
  the InstanceId. Instances started from the same folder read the same INI
  file, so give each one its own `-id`. Two live instances with the same AppId
  are marked "duplicate AppId" in the grid; they still have separate queues.

The form caption shows `LeakWatch [<AppId>] (<InstanceId>)`.

## Configuration

### Command line

| Switch | Meaning |
| --- | --- |
| `-id=<AppId>` | display label of this instance |
| `-mode=A\|B` | generator mode (A = random churn, B = continuous growth) |
| `-autostart` | connect and start the generator after the form is shown |
| `-runfor=<minutes>` | close normally after that time; exit code 0, or 1 if the broker was never reached |
| `-seed=<n>` | random seed of the generator, for repeatable runs |
| `-eventlog=<path>` | detector event log; default `LeakWatch-<AppId>-events.log` next to the exe |
| `-ini=<path>` | INI file; default `LeakWatch.ini` next to the exe |
| `-reportleaks` | sets "report leaks at exit" |

`/name=value` works as well. Unknown switches are logged and ignored.

### INI file

`LeakWatch.ini` next to the exe; all keys are optional. See
[`LeakWatch.ini.example`](LeakWatch.ini.example) for every key with its
default. Sections: `[Broker]` (Host, Port, User, Password, VHost, TimeoutMs),
`[App]` (AppId, IntervalMs, PollMs, StoreCapacity), `[Detector]` (see the
tuning guide) and `[Generator]` (the defaults of the generator controls).

Clicking Connect with changed broker settings saves them to the INI file.
**The password is stored in plain text.**

### Event log

Each instance writes one tab-separated UTF-8 line per detector event:

```
SEEN   <utc> <observer AppId> <observer InstanceId> <subject AppId> <subject InstanceId>
LEVEL  <utc> <observer...> <subject...> <old level> <new level> <explanation>
FINAL  <utc> <observer...> <subject...> <sample count> <final level> <max level>
```

`FINAL` lines are written when the consumer stops (Disconnect or exit).

## Multiple instances and the acceptance test

Every instance is producer and consumer at the same time; start as many as
you like, on one or more machines pointing to the same broker. Each one sees
all of them.

**Manual test:** start three instances,

```
LeakWatch.exe -id=WS-01 -mode=A -autostart
LeakWatch.exe -id=WS-02 -mode=B -autostart
LeakWatch.exe -id=WS-03 -mode=A -autostart
```

and wait about ten minutes. All three must show `WS-02` as *Likely* and
`WS-01` and `WS-03` as *None*. (In the reference run, `WS-02` was flagged
after 9 minutes on all three instances; the others stayed at *None* for the
whole 20 minutes.)

**Scripted test** (Windows PowerShell 5.1):

```
powershell -ExecutionPolicy Bypass -File test\acceptance.ps1
```

It checks the broker, builds, starts the three instances for 20 minutes
(`-Minutes` to change), then checks every event log: all three AppIds were
seen, `WS-02` reached *Likely*, `WS-01` and `WS-03` never left *None*, and
every process exited with code 0. It prints a pass/fail table and exits
non-zero on failure. Parameters: `-BrokerHost`, `-Port`, `-User`,
`-Password`, `-VHost`, `-Minutes`, `-Seed`, `-NoBuild`.

## The leak detector

The detector runs per instance in the consumer thread, after each batch, over
the newest `WindowSamples` samples (default 300, i.e. 10 minutes at 2 s).
The x axis is time in seconds, so gaps in the data do not distort anything.

Before any verdict:

- samples from the first `StartupIgnoreSeconds` (120) after the process start
  are ignored (start-up allocations, generator fill-up),
- the remaining window must span `MinDataSeconds` (420), or be full.

Four heuristics each give a score from 0 to 1 and an explanation:

| Heuristic | Looks at | Score 1 when |
| --- | --- | --- |
| Trend | linear regression of allocated bytes and of block count over time | slope at or above the threshold with R² ≥ `MinR2` |
| Monotonic growth | share of steps where allocation did not decrease | share ≥ `MonotonicShare` and net growth |
| Low-water mark | the minimum of 8 overlapping sub-windows, each half the window long | the floor rose by at least the threshold rate |
| No release | time since the last drop of more than `DropPercent` | no drop for `NoReleaseMinutes` with growth at the threshold rate |

Each score ramps from 0 at half the threshold to 1 at the threshold. The
scores are combined with a weighted noisy-OR, `1 - Π(1 - weight × score)`,
so one strong signal is enough, while a weak one (such as monotonic growth
alone, which a harmless sawtooth also shows) is not. A hysteresis turns the
score into a level: it rises after `RaiseCount` (3) evaluations above a
threshold, and falls after `FallCount` (10) evaluations below the threshold
minus `FallMargin`.

Why overlapping sub-windows for the low-water mark: with 8 disjoint segments
of a 10-minute window, a segment is 75 seconds long and often contains no
trough of a 3-minute release cycle. Its minimum is then a point on the way
up, and a harmless sawtooth looks like a rising floor. A sub-window of half
the window contains at least one trough of any cycle shorter than that.

A size-class hint (which small block sizes grew most, plus medium and large
block totals) is logged with each warning. The memory manager has no
per-class breakdown for medium and large blocks.

Example warning, from an acceptance run (Mode B with default settings, raised
9 minutes after the start on all three instances):

```
LEAK LIKELY – app 'WS-02' (PC1-13184): +5.5 MB/min, low-water mark +19.7 MB, rising in 7 of 7 steps, no release for 7.1 min (+38.8 MB)
```

Numbers in warnings and the log follow the Windows locale (a German system
shows `5,5`).

### Expected results (unit tests)

| Synthetic series (2 s samples) | Result |
| --- | --- |
| Flat with ±5 % noise | None |
| Random churn (simulation of Mode A, after warm-up) | None |
| Sawtooth, 3-minute cycle, everything released | None |
| Sawtooth, 3-minute cycle, 10 % of each cycle stays | Likely |
| Steady leak, 2 MB/min with noise | Likely (within 10 minutes) |
| Step of +20 MB, flat before and after | Suspected or Likely around the step, None once the window has passed it |
| Steady leak with gaps of 30 s and 2 min | Likely |
| Less data than `MinDataSeconds` | not evaluated, None |
| Fill-up during the start-up phase | None |

## Detector tuning guide

All settings are in the `[Detector]` section of the INI file.

- **`SlopeThresholdKBPerMin`** (256) is the main knob: the growth rate you
  call a leak. Set it well above the normal growth of the watched program,
  but below the smallest leak you care about. LeakWatch's own heap (store,
  buffers, logs) is pre-allocated or bounded, so its growth after start-up is
  close to zero.
- **`WindowSamples`** (300) × the snapshot interval is the window length.
  Longer windows catch slower leaks and tolerate longer release cycles, but
  react later. The window should cover **at least two release cycles** of the
  watched program: a sawtooth with a cycle longer than half the window looks
  like steady growth and is correctly reported as a leak *within* that window.
- **`MinDataSeconds`** (420) delays the first verdict. Keep it at least twice
  the longest release cycle, for the same reason.
- **`StartupIgnoreSeconds`** (120) hides the start-up phase. Starting the
  generator (or any big cache) later is a step in memory and may raise a
  temporary warning until the window has slid past it.
- **`MinR2`** (0.8): lower it for noisy programs whose trend you still want
  to see; the low-water mark heuristic does not need a good fit.
- **`DropPercent`** (5) and **`NoReleaseMinutes`** (5) define "released":
  a drop of more than 5 % below the recent peak resets the no-release clock.
- **Weights**: `WeightLowWater` (0.9) and `WeightTrend` (0.8) are the strong
  signals, `WeightMonotonic` (0.3) is a hint only. Raise `WeightNoRelease`
  (0.6) for programs that should release memory regularly.
- **`SuspectedThreshold`** (0.4), **`LikelyThreshold`** (0.7), **`RaiseCount`**
  (3), **`FallCount`** (10), **`FallMargin`** (0.1): raise the counts if levels
  flicker, lower them for faster reactions.

A reconnect (Disconnect, Connect) starts a new consumer with fresh detector
state; the stored samples are kept.

## Tests

```
test\run-tests.cmd                 unit tests (no broker needed)
test\run-tests.cmd -integration    also the transport and thread tests against localhost:15672 (guest/guest)
test\run-tests.cmd -gui            DUnit GUI runner
```

The unit tests cover the JSON format (escaping, Int64, German locale), the
store (duplicates, out-of-order, wrap-around, restarts, staleness), the
detector with the synthetic series above, `TMemStats.Capture` (that it
queries the memory manager in use; with FastMM4 also against FastMM4's own
`GetMemoryManagerUsageSummary`), the request bodies and response parsing,
the configuration and the leak generator. Run them once with
`LEAKWATCH_FASTMM4=1` as well when you change `uMemStats`.

## Known limitations

- **HTTP polling is not meant for production.** Every publish and every poll
  is a separate HTTP request, and new snapshots arrive only with the next
  poll. For anything bigger, put a STOMP client (for example the
  [Habari STOMP Client](https://habarisoft.com) libraries), AMQP or the
  stream protocol behind `ISnapshotTransport`; see
  [above](#why-a-fanout-exchange-and-not-a-stream).
- **Memory manager statistics are a point-in-time view** of the whole heap,
  including LeakWatch's own allocations (Indy, JSON, the store). A short burst
  between two snapshots is invisible; a slow leak shows only over minutes.
- **No per-allocation call stacks.** They need FastMM4's FullDebugMode
  (optional FastMM4 build, not configured here). The size-class hint is the
  only attribution.
- **The leak report at exit is a message box** (neither the built-in manager
  nor FastMM4 without FullDebugMode writes a log file), and the process waits
  until it is closed.
- Timestamps of different machines are never compared: the series of an
  instance uses its own timestamps, staleness the receiver's clock.
- The INI file stores the broker password in plain text.

## Licence

MIT, see [LICENSE](LICENSE). The optional FastMM4 in `third_party/FastMM4`
is dual licensed under MPL 1.1 and LGPL 2.1 (see its README). Indy and
JsonDataObjects are not part of this repository and have their own licences.
