# Apex Replay Debugger — Phase 0 findings

Source: `salesforce.salesforcedx-vscode-apex-replay-debugger` v67.17.16 and
`salesforce.salesforcedx-vscode-apex` v67.17.16, downloaded from Open VSX
(2026-09-18) and unzipped. Node used for grepping/testing: v25.2.1 (system
node; the adapter is plain JS, no version-specific syntax found).

VSIX download used (works without a Marketplace account):
```
https://open-vsx.org/api/salesforce/<ext-id>/<version>/file/salesforce.<ext-id>-<version>.vsix
```

## Adapter entry point

`extension/package.json` → `contributes.debuggers[0]`:
```json
{ "type": "apex-replay", "program": "./dist/apexReplayDebug.js", "runtime": "node" }
```
So the adapter command is `node <vsix-root>/extension/dist/apexReplayDebug.js`.
This matches the plan's assumed auto-detect path shape.

## ⚠️ Deviation from the plan — `logFile` is NOT read by the adapter

The plan (§0) assumes the DAP `launch` args carry `logFile: "<path>"` and the
adapter reads the file. **That is not what the installed adapter does.**

`apexReplayDebug.js`'s `LogContext` constructor:
```js
constructor(e, t) {
  this.launchArgs = e;
  this.session = t;
  this.logLines = readLogFileFromContents(e.logFileContents);
  this.logSize  = getFileSizeFromContents(e.logFileContents);
}
getLogFileName() { return this.launchArgs.logFileName; }
getLogFilePath() { return this.launchArgs.logFilePath; }
```
`readLogFileFromContents` is `text => text.trim() === "" ? [] : text.trim().split(/\r?\n/).map(l => l.trim())`.
There is **no file read inside the DAP adapter process at all.**

The *file reading* happens on the VS Code extension-host side, in
`salesforcedx-vscode-apex-replay-debugger`'s `resolveDebugConfiguration`
(`extension/dist/index.js`), **before** the adapter process is even spawned:
```js
if (t.logFile && t.logFile !== DEFAULT_ASK_SENTINEL) {
  t.logFileContents = await readFile(t.logFile);   // plain text, not base64
  t.logFilePath = t.logFile;
  t.logFileName = basename(t.logFile);
  delete t.logFile;
}
```
This preprocessing is VS Code UI glue we are not using. **Since nvim-dap talks
DAP directly to the adapter process, we must do this preprocessing ourselves**
and send the launch request with:
```jsonc
{
  "type": "apex-replay",
  "request": "launch",
  "logFileContents": "<full text content of the .log file, as a string>",
  "logFilePath": "/abs/path/to/file.log",   // display only, not re-read
  "logFileName": "file.log",                 // display only (basename)
  "stopOnEntry": true,
  "trace": false,
  "lineBreakpointInfo": [ ... ]
  // NOTE: no "logFile" key — it is never read by this adapter version
}
```
**Action required for Phase 1:** `Debug.launch(log_path)` must read the log
file into a Lua string (`vim.fn.readfile(path)` joined with `\n`, or
`io.open`) and set `logFileContents` + `logFilePath` + `logFileName` instead
of `logFile`. The plan's §1.4 and the `dap.run{...}` example need updating
accordingly — flagging per hard rule #6, not guessing further; human should
confirm this matches their working POC config (see open question below).

Everything else in the plan's §0 was confirmed exactly as written (details
below), so this looks like a real behavior change/version drift versus the
`develop` branch source the plan was written against, not a misreading.

## `lineBreakpointInfo` — confirmed exact

`launchRequest(e, t)` in `apexReplayDebug.js`:
```js
launchRequest(e, t) {
  let s = false;
  if (t?.lineBreakpointInfo) {
    s = true;
    Fs.breakpointUtil.createMappingsFromLineBreakpointInfo(t.lineBreakpointInfo);
    delete t.lineBreakpointInfo;
  }
  ...
  if (!this.logContext.hasLogLines())              -> error "no_log_file_text"
  else if (!this.logContext.meetsLogLevelRequirements()) -> error "incorrect_log_levels_text"
  else if (!s)                                     -> error "session_language_server_error_text"
  else { ...launch succeeds... }
}
```
So: missing/empty `lineBreakpointInfo` → the exact "language server" error
the plan describes. Confirmed **required**, confirmed **deleted from args**
after use.

`createMappingsFromLineBreakpointInfo(entries)` iterates entries and reads
`.uri`, `.lines` (array, appended per uri) and `.typeref` (mapped 1:1 per
uri). So the shape is confirmed exactly:
```ts
{ uri: string, typeref: string, lines: number[] }[]
```

## `debugger/lineBreakpoints` LSP request — confirmed exact

Found in `salesforcedx-vscode-apex`'s bundle, not the replay-debugger bundle
(the replay-debugger extension calls into the core Apex extension's exported
API, which wraps the LSP call):
```js
DEBUGGER_LINE_BREAKPOINTS = "debugger/lineBreakpoints";
async getLineBreakpointInfo() {
  return this.clientInstance
    ? this.clientInstance.sendRequest(DEBUGGER_LINE_BREAKPOINTS)  // no params
    : [];
}
```
Confirmed: **no params**, response is the array shape above (or `[]`).
`client:request("debugger/lineBreakpoints", nil, cb)` is correct.

Also confirmed the VS Code side polls `languageClientManager.getStatus().isReady()`
before calling `getLineBreakpointInfo()` (a bounded loop) — matches plan's
"poll then error" guidance; exact interval/count in that bundle wasn't fully
extracted (obfuscated loop var names) but the polling behavior is real, not
speculative. Phase 1's own `lsp_timeout`-bounded retry does not need to match
VS Code's exact 100ms×30 to be correct.

## `stopOnEntry` / `trace` — confirmed exact

```js
configurationDoneRequest(e, t) {
  this.logContext.getLaunchArgs().stopOnEntry
    ? (this.logContext.updateFrames(), this.sendEvent(new StoppedEvent("entry", THREAD_ID)))
    : this.continueRequest({}, { threadId: THREAD_ID });
}
setupLogger(e) {
  typeof e.trace === "boolean"
    ? (this.trace = e.trace ? ["all"] : [], this.traceAll = e.trace)
    : typeof e.trace === "string"
      ? (this.trace = e.trace.split(",").map(t => t.trim()), this.traceAll = this.trace.includes("all"))
      : undefined;
}
```
Trace category strings, confirmed verbatim: `all`, `protocol`, `logfile`,
`launch`, `breakpoints`. Matches plan exactly.

## `heapDumpResults` / `projectPath`

`heapDumpResults` is read (`t.heapDumpResults ?? []`) only if the log
contains `|HEAP_DUMP|` lines — out of scope per plan, confirmed harmless to
omit. No reference to `projectPath` anywhere in the adapter bundle —
confirmed plan's claim that it's unused.

## Open question for the human

1. Do you still have the hand-rolled POC launch config that worked for you?
   If so, please save it as `tests/fixtures/replay_launch_poc.json` (or paste
   it) — specifically I need to confirm whether your POC used `logFile` or
   `logFileContents`, since that determines whether the deviation above is
   version drift or whether an even older/different adapter build is in play.
2. Everything else in Phase 0 is confirmed and needs no further discovery.

## Adapter auto-detect paths (for Phase 1 config)

- Open VSX download used above → good default source for an "install adapter"
  helper (Phase 4.2), no Marketplace login needed.
- VS Code local install path pattern (if present):
  `~/.vscode/extensions/salesforce.salesforcedx-vscode-apex-replay-debugger-*/extension/dist/apexReplayDebug.js`
- Our own stdpath cache used for this investigation:
  `~/.local/share/sf-nvim/apex-replay-debugger/extension/dist/apexReplayDebug.js`
  (matches the `<program>` layout the plan assumed: `extension/<program>`).
