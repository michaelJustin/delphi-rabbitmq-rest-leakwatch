# FastMM4 (vendored, optional)

LeakWatch uses the memory manager built into the RTL by default. This copy
of FastMM4 is used only when the conditional define `LEAKWATCH_FASTMM4` is
set (see the main README, section "Memory manager").

- Upstream: https://github.com/pleriche/FastMM4
- Version: tag `release_4993` (FastMM 4.993, 2021-08-10)
- Licence: dual MPL 1.1 / LGPL 2.1, see `FastMM4_Readme.txt` (section "License").
  The upstream `README.md` is kept as `UPSTREAM-README.md`.

Vendored files: `FastMM4.pas`, `FastMM4Messages.pas`, `FastMM4Options.inc`,
`FastMM4_Readme.txt`. The optional units `FastMM4LockFreeStack.pas` and
`FastMM4DataCollector.pas` are not included: they are only used with the
`UseReleaseStack` and `LogLockContention` options, which stay off.

## Why vendored and not a submodule

`FastMM4.pas` includes its options with `{$Include FastMM4Options.inc}`. The
Delphi compiler resolves that include **next to `FastMM4.pas` first**, even
when `-I` points elsewhere (checked with dcc32 of Delphi 2009). A
project-specific options file therefore has to replace the upstream one in
this folder, which a submodule would not allow.

## Changes to `FastMM4Options.inc`

Only these two lines differ from upstream; each carries a `LeakWatch:` comment.

| Option | Upstream | Here | Reason |
| --- | --- | --- | --- |
| `RequireDebuggerPresenceForLeakReporting` | on | off | Report leaks also when the program runs outside the IDE debugger. |
| `ManualLeakReportingControl` | off | on | The shutdown leak report is switched at runtime with `ReportMemoryLeaksOnShutdown` (the variable in `System`, Delphi 2006 and later). LeakWatch sets it from the "report leaks at exit" checkbox. |

`FullDebugMode` stays off. Without it, the leak report at shutdown is shown as
a message box (no log file, no call stacks).
