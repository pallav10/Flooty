# Flooty

The agent-harness that drives a live terminal: a real PTY in a native window, an
autonomous agent loop in front of it, and a per-session transcript the app owns.

Part of the Flooty family (`FlootyPTYLayer` renders the window, `FlootySessions`
/`FlootyPersistence` own what the family stores, `FlootyStreams` defines the
message vocabulary).

## What it does

- **One PTY per tab, driven by both sides.** The user types at the prompt; the
  agent types statements/evaluations into the same REPL. Ownership is arbitrated
  (`ControlState`): typing or Take Over flips input to the user, and the loop
  parks instead of fighting it.
- **An agent loop** (`flootyAgentLoop.jl`) that snapshots the terminal, asks a
  model for exactly ONE JSON action, and executes it. Loop guards REFUSE/STEER
  repeated or unparseable turns but do not deterministically stop the run:
  termination comes from `done`, a caller-configured `maxTurns`, the user taking
  over, or the monitors/user. The app runner uses `maxTurns=0` (unbounded).
- **Transcripts the app owns** (`conversation.jl`): every turn is recorded in the
  family's message vocabulary (`MessageItem` wrapping `OllamaMessage`), the page
  renders it, and the next run is seeded from a bounded tail of it.
- **Persistent sessions**: the app writes each transcript through to the family's
  store as it happens, so a restart does not lose the conversation.

## Installation

Not in a registry yet — install from the checkout with Julia 1.12. Required
`[sources]` dependencies must sit beside it: `FlootyAbstract`, `FlootyBase`,
`FlootyPTYLayer`, `FlootyPersistence`, and `FlootyStreams`; the terminal layer
also needs `FlootyREPLBridge` and `ShadowTerm`. Webviews and WebIO resolve from
the registry; no machine-specific WebIO checkout is needed.

```julia
using Pkg
Pkg.develop(path = "/path/to/Flooty")
```

From the parent directory:

```sh
julia --startup-file=no --project=Flooty -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=Flooty Flooty/agentUi.jl 0
```

`FlootySessions` is optional and loaded only by `activateReplTool!`, the legacy
REPL-tool bridge. Install its genuine package and dependencies in the active
environment before calling that API; the desktop app does not require it.

### As an app (Julia ≥ 1.12)

The package declares an app entry point (`[apps.flooty]`), so `Pkg.Apps`
can install a launcher into `~/.julia/bin`:

```julia
using Pkg
Pkg.Apps.develop(path = "/path/to/Flooty")   # writes ~/.julia/bin/flooty
```

```sh
flooty                                            # open the window (all options optional)
flooty --help                                     # usage
flooty "run the test suite and summarize the failures"
```

Every option is optional: with no arguments the app simply launches, and the
window uses the UI layer's default geometry unless `--width`/`--height` say
otherwise.

The shim is `julia -m Flooty "$@"`, so the equivalent direct invocation is:

```sh
julia -m Flooty [--width N] [--height N] [--sessions DIR] ["<instruction>"]
```

Window geometry is optional: `--width`/`--height` are overrides, and when either is
omitted the UI layer's own default applies (`FlootyPTYLayer.launchTerminalUI`),
because the app does not own pixels it has no reason to know about.

(Keep `~/.julia/bin` on `PATH`; `Pkg.Apps.status()` warns if it is missing.)

## Terminal themes

The status-bar **Theme** selector applies a palette to every open terminal,
the window chrome, chat, and code editors without restarting sessions. Bundled
themes are `Flooty Dark` (default), `Flooty Light`, and `Dracula`. The previous
wallpaper and grain overlay are no longer used.

Selection is saved in `~/.flooty/theme.conf`. This file accepts Ghostty-style
settings; color overrides take precedence over the selected theme:

```ini
theme = Flooty Dark
background = #15171e
foreground = #e4e6ed
palette = 4=#6196eb
```

To import a Ghostty color theme, copy its file to `~/.flooty/themes/My Theme`
and choose `My Theme` in the selector. Supported keys are `background`,
`foreground`, `cursor-color`, `cursor-text`, `selection-background`,
`selection-foreground`, and repeated `palette = 0..15=#rrggbb` entries.
Colors require six hexadecimal digits, with an optional `#`; quoted values
and whole-line comments are accepted. Unrelated Ghostty settings are ignored.
User theme files override bundled themes with the same name.

**Reload** re-reads the config and theme files after manual edits. Invalid
startup configuration shows an error and uses the bundled default without
rewriting the config; failed selections leave the current palette unchanged.
`FLOOTY_THEME_CONFIG` and `FLOOTY_THEMES_DIR` override the two locations.
Julia callers can use `FlootyPTYLayer.ThemeManager.themeState()`,
`loadTheme(name)`, `availableThemes()`, and `selectTheme!(name)`.

## Reading files

The driver reads through the terminal, like a person would:

```json
{"action":"send","code":"bat --paging=always --pager=less src/app.jl"}
```

The pager owns the pane; scroll with `{"action":"type"}` space/PgDn and quit
with `q`. For a bounded non-interactive view use `bat --paging=never FILE` (or
`head`/`tail`/`sed -n 'A,Bp'`); never dump a whole large file. On an SSH pane the
same command runs on the remote host. In a Julia REPL prefer the `TerminalPager`
package when available: `using TerminalPager; pager(read("src/app.jl", String))`.

## Per-tab models

Each chat, terminal, or browser session has two independent status-bar pickers:

- **Agent:** answers requests and runs terminal tasks. A change applies to the
  next request or task; a task already running keeps its original model.
- **Monitor:** watches progress and provides background feedback. A change
  applies to the next background check.

Open **Model help** beside the pickers for these roles and timing rules.
Selections affect only the active session, not other sessions or process defaults.
`agentModelState(id)`, `selectAgentModel(name, id)`, and
`selectMonitorModel(name, id)` address the session; `sessionModelConfig(sess)`
supplies its configuration. Model discovery runs in background tasks.

## Slash actions and subscription login

Type `/` in the agent composer to see available actions. Arrow keys select,
Enter runs an action, Tab completes its name, and Escape dismisses the menu.
Commands are local UI actions, not terminal input or model prompts. `/login`
is the initial action; its catalog and dispatcher live in `src/slashCommands.jl`.

`/login` opens a private subscription dialog:

- **GitHub Copilot:** confirm your GitHub host, then approve the displayed device
  code in your browser. Use `github.com` for normal personal/Business accounts, or
  your enterprise sign-in host (for example `company.ghe.com`) for GHE accounts.
  A hostname or HTTPS root URL is accepted; an empty field uses `github.com`.
  Enterprise login uses the Copilot CLI OAuth client, which your organization
  must permit. The saved host scopes token refresh, model discovery, and inference;
  switching hosts does not reuse another tenant's credentials or model catalog.
- **Claude Code:** requires the official `claude` executable on PATH. Flooty runs
  its unmodified login and tool-disabled inference; Claude Code owns credentials
  and refresh. Flooty does not collect or route Claude subscription tokens.
- **xAI / Grok:** open the consent page, then paste the full redirect URL into the
  dialog, even if the loopback page fails to load. Account entitlement and quotas
  are determined by the provider, not an assumed subscription tier.

After connecting, choose **Use model** to select a model for the active session.
Subscription IDs are qualified as `github-copilot/<model>`,
`claude-code/<alias>`, or `xai/<model>`; unqualified models retain the configured
OpenAI-compatible endpoint. Copilot/xAI credentials and rotated refresh tokens
are stored in macOS Keychain, separately from transcripts and preferences.
Only connect accounts whose provider and organization policies permit this use.

## Streaming thinking

Reasoning is streamed while the model generates it: `streamCompletion` reads the
stream (native Ollama `/api/chat` when the endpoint is an Ollama host — the
FlootyStreams transport FlootyTUI uses — else OpenAI-compatible SSE) and calls
`onThinking(chunk)` per reasoning delta. The loop coalesces those into live
`AgentThinkingEvent`s (first chunk immediately, then every 150 ms / 400 chars) and
records the FULL thinking once at the end of the turn, so the chat animates and
the transcript stays one message. Non-streaming bodies fall back to the one-shot
path automatically. Note: the configured `beam:cloud` emits its deltas in one
burst, so the animation only shows with models that stream.
Subscription adapters currently buffer replies and deliver thinking after the
response completes, rather than streaming it live.


## Context window

The model's window is read from the endpoint (`/api/show` →
`model_info.*.context_length`; measured `beam:cloud` = **1 048 576**), overridable
with `FLOOTY_CONTEXT_LENGTH`. Each turn's status line reports the estimated
footprint (`ctx 12.3k/1048.6k (1%)`, chars/4 heuristic), and when it crosses
`CONTEXT_COMPACT_AT` (85 %) the loop folds older turns into ONE digest — system
prompt and the last 8 messages are kept, no extra model call. The agent can ask
for it earlier with `{"action":"compact"}`; the API is `contextLengthFor`,
`contextUsage`, `estimateTokens`, `compactMessages!`.

## Parallel sends

A driver can run **independent** commands in different panes concurrently:

```json
{"action":"parallel","sends":[
  {"target":"main","code":"make -j4"},
  {"target":"split","code":"julia --project=. -e 'using Pkg; Pkg.test()'"}
]}
```

Each pane gets at most one send; targets are `main` and `child:N` (a split or
a terminal tab; `split` aliases the newest split). Execution is one Julia task
per pane, and the driver receives one `ACTION RESULT: parallel 3/3 ok in 1.2s`
with per-item output. The same pane twice, an idle-prompt violation, or an
interactive command refuses the batch before anything runs. Use it only for
work that does not touch the same files or depend on the other item.

## Child sessions

A session can launch a **child session**:

- from a chat: `{"action":"chat","name":"…"}` opens a child `ChatSession` in its
  own tab (the root "Chat" tab stays available); the child has its own
  conversation and model turns, and the assist box follows the active tab;
- from a terminal: `{"action":"newChat"}` does the same; `newTerminal` opens a
  child **terminal** tab. The `TerminalSession` is parented to the **requesting**
  session, so its monitor insights and status traces reach that driver. A split
  pane is also a child of its main terminal.
- Only the first terminal whose parent is the root chat adopts the chat-only
  thread; children of a child do not inherit it.

## Browser and SSH sessions

Two more session types (root or child; both nest in the tab rail):

- **Browser** (`Ctrl+Shift+T` → Browser session): a browser panel with a URL
  bar and iframe plus a chat rail. The driver can navigate/reply
  (`{"action":"navigate","url":…}`); the user can type URLs directly. Pages are
  displayed in an iframe; cross-origin pages are not readable by the driver
  (navigation is the action surface), and `Open` sends the URL to the system
  browser.
- **SSH** (`Ctrl+Shift+T` → SSH session): the session's PTY runs
  `ssh <user@host>`; every child terminal (tab, split, or agent `newTerminal`)
  inherits the SSH command/target and starts its own login to that remote. The
  `TerminalSession` records `kind=:ssh` and the remote target.

## The session tree

The sessions form an **n-ary tree**; the screen shows one arena at a time:

- the **arena** holds the session in view on the LEFT and its (at most two)
  children stacked on the RIGHT. A session with no children takes the whole
  area. Clicking a child's pane promotes it (the view descends into it), and
  `Alt+D` opens the radial dial to spawn another child;
- the **LEFT rail** is the ribbon of **root-session icons** (terminal, chat,
  SSH, browser) with a busy dot; an icon takes that session's arena;
- the **tree map** (`Ctrl+Shift+O`) draws the whole tree with one strip per
  level (the session and its children); clicking a session selects it;
  `Ctrl+Shift+R` opens the radial dial for a new **root** session and
  `Ctrl+Shift+T` for a **sibling** of the session in view;
- `Ctrl+Tab` cycles the sibling group — the peers of the session in view —
  not the children, which are already on screen;
- the **RIGHT rail** is the chat + monitoring panels of the session in view
  (the app's conversation, its monitors, and the assist box).

## Child sessions
## Child sessions

A session can launch a **child session**:

- from a chat: `{"action":"chat","name":"…"}` opens a child `ChatSession` in its
  own tab (the root "Chat" tab stays available); the child has its own
  conversation and model turns, and the assist box follows the active tab;
- from a terminal: `{"action":"newChat"}` does the same; `newTerminal` opens a
  child **terminal** tab. The `TerminalSession` is parented to the **requesting**
  session, so its monitor insights and status traces reach that driver. A split
  pane is also a child of its main terminal.
- Only the first terminal whose parent is the root chat adopts the chat-only
  thread; children of a child do not inherit it.

## Browser and SSH sessions

Two more session types (root or child; both nest in the tab rail):

- **Browser** (`Ctrl+Shift+T` → Browser session): a browser panel with a URL
  bar and iframe plus a chat rail. The driver can navigate/reply
  (`{"action":"navigate","url":…}`); the user can type URLs directly. Pages are
  displayed in an iframe; cross-origin pages are not readable by the driver
  (navigation is the action surface), and `Open` sends the URL to the system
  browser.
- **SSH** (`Ctrl+Shift+T` → SSH session): the session's PTY runs
  `ssh <user@host>`; every child terminal (tab, split, or agent `newTerminal`)
  inherits the SSH command/target and starts its own login to that remote. The
  `TerminalSession` records `kind=:ssh` and the remote target.

## The session tree

The sessions form an **n-ary tree**, and the layout is a **k-d tree** of it:
a node's own pane is on the LEFT, its (at most two) children on the RIGHT,
stacked. The cell repeats at every level — a child pane, zoomed in, is the
same shape. A node with **no children takes the whole area**.

- the app boots with the **chat session as the default root**; `Ctrl+Shift+R`
  opens the chooser for another **root** session (a terminal, a chat, an SSH
  target, a browser) — the radial dial — and `Ctrl+Shift+T` for a **sibling**
  of the session in view;
- the **tree map** (`Ctrl+Shift+O`) draws the whole tree, one row per session;
  clicking a row puts that session in view;
- the status bar's **`↑ parent`** button (and the tree map's) goes **up** the
  tree: the parent session takes the view;
- the tree map's **`⇧` button** makes the picked session the parent of the
  session in view. The move is refused when it would put a session under its
  own descendant;
- the chat and monitoring panes follow the node: a root and a node with
  children show them, a **leaf child hides them** (its terminal gets the room)
  and the `☰` handle at the arena's right edge opens them;
- the LEFT rail is a compact column of square ROOT-session icons (terminal,
  chat, SSH, browser) with a busy dot; a root icon takes the view.

## Child sessions

A session can have children — a terminal session, a chat session:

- `splitTerminal`/`newTerminal` open a **child terminal session** (a node of
  the tree, shown in the parent's right half); `newChat` opens a child chat
  session;
- children are addressed with `{"action":"send","code":"…","target":"child:N"}`
  (`"split"` is an alias for the newest child);
- each child has its own monitor and its own standing agent, and its insights
  reach the parent's driver as MONITOR NOTEs;
- `closeSplit` closes the child sessions.

- `Alt+D` opens a child terminal as a **vertical** split (side by side);
  `Alt+Shift+D` as a **horizontal** split (stacked). The status-bar `split` button
  opens a vertical split; once a pool exists the button becomes `close split`;
- the child sessions appear in the RIGHT half of the arena, stacked (the
  session tree above); the active path's sessions also appear in HORIZONTAL
  strips above the content (one strip per level: `self` + its children);
  clicking a strip tab selects that session and re-fits the split layout;
- the agent opens one with `{"action":"splitTerminal"}` and repeats it for a
  second (max two); it closes them with `{"action":"closeSplit"}` — TEMPORARY
  panes for work the main pane cannot do right now (it is inside a REPL/editor,
  for example); close them when done;
- targets are `"target":"child:1"`, `"child:2"` (ALL child terminals, split or
  tab); `"split"` aliases the newest split presentation;
- the USER may use it too. The main driver's snapshot reports `split=open` with
  the child's pending input, and the child monitor's user-intent insights are
  forwarded to the main driver as `split pane: …` MONITOR NOTEs — one shared
  view of both panes;
- the child belongs to ITS tab: switching tabs hides it (the session keeps
  running), switching back shows it again, and closing the tab closes the child;
- closing the tab with ✕ on the child also works: it has no tab of its own, so
  use the status-bar `close split` button or the agent's `closeSplit`.

## Layout

The app boots **chat-only**: the assist bar talks to the chat model. When an
instruction needs a real terminal, the chat driver opens one itself
(`{"action":"terminal","task":"…"}`) — the FIRST terminal is seeded with the
chat thread and carries its own monitor and standing agent, which runs the task.
Later terminals start clean (no inherited chat context), so a new pane cannot
resume an earlier task. `Ctrl+Shift+T` opens the NEW ROOT session chooser
(terminal / chat); `Alt+D` / `Alt+Shift+D` spawn a child terminal split
(vertical / horizontal). The agent can also spawn with `newTerminal`,
`splitTerminal` (`orientation`), or `newChat`. Drag the
chat pane's left edge to resize it (double-click the grip to reset); the width
is remembered across launches.

## Usage

```sh
# From the checkout (no app install needed):
julia --project=. agentUi.jl [timeoutS] ["<instruction>"]
```

```julia
using Flooty
Flooty.runAgentApp(task = "run the test suite and summarize the failures")
```

With no instruction the window opens and you commission the tab's agent from the
assist box. Close the window to quit; `agentUi.jl`'s optional first argument is a
watchdog in seconds.

### Journal (event log)

Every recorded turn is also appended to an **event journal** (SQLite today, Arrow
shards later) — one row per event, schema-versioned, sessions as a projection:

```sh
flooty --journal ~/.flooty/journal.sqlite "run the tests"
```

| | |
|---|---|
| file | `~/.flooty/journal.sqlite` (`--journal FILE`; next to `--sessions DIR` in probes) |
| rows | `user_instruction`, `assistant_text`, `assistant_thinking`, `tool_call`, `tool_result`, `session_started`, `session_adopted` (+ `eval_outcome`, …) |
| identity | `session_uid` is minted once per session — adoption cannot re-key it |
| load a session | `journalSessionList()` → `journalConversation(uid)` → feeds `conversationContext` |
| health | `journalDoctor()`, `FlootyPersistence.journal_events(j; session_uid = uid)` |
| schema | `schema_version` column per row; old rows are upcast, newer rows raise |

The JSON transcripts (`~/.flooty/conversations`) keep being written for one release
as the export path; the journal is the durable half. Design:
`FlootyArchitecture/JOURNAL_AND_INDEX_STORE.md`.

### Sessions

| | |
|---|---|
| store | `~/.flooty/conversations/<session-id>.json` (override with `--sessions DIR`) |
| format | `ConversationData` (`FlootyPersistence.JSONBackend`, JSON3 + StructTypes) |
| when | every recorded turn, written through as it happens |
| restore | `conversationFor(id)` returns a stored transcript instead of an empty one |
| list | `savedConversations()` — newest first |
| delete | `forgetConversation!(id)` drops the transcript from memory *and* disk |
| force-save | `saveConversations!()` |

Persistence is owned by the **app**: `agentApp`/`runAgentApp` turns it on, while
headless `runTerminalAgent!` runs keep their transcript in memory only, so
scripts and probes never write to your home directory.

A model configuration is per process (`AGENT_CONFIG`), settable from the page's
model picker or `configureAgent!`; the endpoint/model default to the MiniMax
actor model (`FLOOTY_ACTOR_MODEL` / `FLOOTY_MONITOR_MODEL` / `FLOOTY_API_KEY`).

## Future plans

Terminal command history (`Ctrl+R` palette), persisted chat scrollback/recall, asciicast
recording, and the uniform Arrow-backed history/index store are planned but **not
implemented** — see
[`../FlootyArchitecture/HISTORY_AND_INDEXING_PLAN.md`](../FlootyArchitecture/HISTORY_AND_INDEXING_PLAN.md).
That document also carries the plans for the `FlootyCodeIndexer` (JuliaSyntax /
tree-sitter), `FlootyPDFIndexer` (OCR) and `FlootyAudioIndexer` upgrades, including the
current defects it is meant to fix.

## Tests

```sh
julia --project=. test/ptyReplTests.jl            # tool layer + session plumbing
julia --project=. test/conversationProbe.jl      # transcript + seeding
julia --project=. test/conversationPersistenceProbe.jl   # store + process restart
julia --project=. test/providerCallProbe.jl      # native tool-call translation
julia --project=. test/journalProbe.jl           # event journal + loading a session back
julia --project=. test/cliProbe.jl               # flooty argument handling (no window)
julia --project=. test/chatLayoutProbe.jl        # chat-only boot, drag-resize, lazy terminal
julia --project=. test/replModeProbe.jl          # Julia REPL modes: switch them, send per mode
julia --project=. test/contextProbe.jl           # model window, usage tracking, compaction
julia --project=. test/thinkingStreamProbe.jl    # streaming thinking (reader + loop)
julia --project=. test/realPathProbe.jl          # REAL completion path (needs the endpoint)
julia --project=. test/tuiDriveProbe.jl          # drive a pager (scroll/quit) + micro (type/save/quit)
julia --project=. test/keyScrollProbe.jl         # PageUp/PageDown scroll chat + terminal
julia --project=. test/chatDiagnosticsProbe.jl   # warn/error land in chat (strip too)
julia --project=. test/actionRecoveryProbe.jl     # truncated/oversized replies recover
julia --project=. test/typeKeysProbe.jl           # type keys decode \r/\x03; empty type stops
julia --project=. test/promptInputProbe.jl        # leftover prompt input blocks send, says how to clear
julia --project=. test/agentChannelProbe.jl       # monitor<->agent notes + agent brief
julia --project=. test/chatOnlyProbe.jl           # chat first; the root chooser opens a terminal
julia --project=. test/chatTerminalLaunchProbe.jl  # chat prompt opens + commissions a terminal
julia --project=. test/terminalContextProbe.jl     # first terminal adopts the chat; later ones stay clean
julia --project=. test/monitorAfterStopProbe.jl    # intent monitoring continues after a run ends
julia --project=. test/terminalSessionProbe.jl    # session tree: terminal child, monitors, traces, steering
julia --project=. test/staleExcerptProbe.jl       # each send's excerpt is its own command region
julia --project=. test/splitMonitorProbe.jl      # split: own monitor/agent; main snapshot + shared insight
julia --project=. test/fullscreenOwnershipProbe.jl # quitting a pager hands the pane back
julia --project=. test/microEditorProbe.jl        # micro: type a story, Ctrl-S, Ctrl-Q, file on disk
julia --project=. test/microEditorAppProbe.jl     # same through the window with the real model
julia --project=. test/streamStallProbe.jl        # a stalled stream FAILS, does not hang
julia --project=. test/linuxRemoteProbe.jl       # send path against a real Linux shell (ssh)
julia --project=. test/linuxRemoteAppProbe.jl    # same, driven through the app's ssh pane
julia --project=. test/perTabModelProbe.jl       # per-tab models (headless)
julia --project=. test/perTabModelPageProbe.jl   # picker follows the active tab (window)
julia --project=. test/splitTerminalProbe.jl     # child terminal: same-tab split, equal halves
julia --project=. test/splitSendProbe.jl         # tandem: send target=split; split keeps the active tab
julia --project=. test/parallelSendProbe.jl       # parallel: distinct panes overlap; same-pane/interactive refused
julia --project=. test/multiPaneProbe.jl          # 3 panes; child:N/split targets; 3-target batch
julia --project=. test/childChatProbe.jl          # child ChatSession tab + its own conversation
julia --project=. test/sessionChooserProbe.jl     # Ctrl+Shift+T root chooser; Alt+D / Alt+Shift+D splits
julia --project=. test/browserSessionProbe.jl      # BrowserSession: panel, iframe, navigate, rail
julia --project=. test/sshSessionProbe.jl          # SSH kind/remote + child terminal inheritance
julia --project=. test/childTerminalProbe.jl      # newTerminal child parented to the requesting session
julia --project=. test/splitChatProbe.jl         # chat renders before/during/after a split
julia --project=. test/agentViewProbe.jl         # exactly what the LLM receives as the pane
julia --project=. test/wireMessageProbe.jl       # request wire form (content never null)
julia --project=. test/modelPickerProbe.jl       # model picker wiring (opens a window)
julia --project=. test/slashCommandsProbe.jl     # local actions, session routing, refresh/cancellation races
julia --project=. test/subscriptionCopilotProbe.jl
julia --project=. test/subscriptionClaudeProbe.jl
julia --project=. test/subscriptionXaiProbe.jl    # synthetic provider boundaries; no live account login
julia --project=. test/copilotEnterpriseSystemProbe.jl # native E2E with a local provider fixture
```

## macOS app (`Flooty.app`)

`flooty` is a terminal command. To get a real Mac application — Dock icon,
app name in the menu bar, Finder/Spotlight launch, double-clickable — build the
bundle:

```bash
scripts/buildMacApp.sh                 # -> ~/Applications/Flooty.app
scripts/buildMacApp.sh --out /Applications   # system-wide (may need sudo)
scripts/buildMacApp.sh --no-sign       # skip the ad-hoc codesign
scripts/buildMacApp.sh --icon assets/flooty-icon.svg
```

Launch with `open "$HOME/Applications/Flooty.app"` for the Flooty Dock name and
Peek puppy icon. Direct Julia launches retain Julia's identity. Rendering SVG
icons requires `swift` from Apple's command line tools.

What it does:

* renders the Peek puppy in `assets/flooty-icon.svg` through Swift/AppKit,
  preserving transparency, builds every iconset size, and packs `Flooty.icns`
  with `iconutil`;
* writes `Contents/Info.plist` (`dev.flooty.agent`, "Flooty", developer-tools
  category, HiDPI) and a launcher that reproduces the `Pkg.Apps` shim environment:
  `JULIA_DEPOT_PATH`, `JULIA_LOAD_PATH=$depot/dev/Flooty`, `cd $HOME`;
* redirects Julia's output to `~/Library/Logs/Flooty.log` and sets
  `FLOOTY_APP_BUNDLE=1`, which makes the app flush stdout/stderr once a second (a
  file redirect is block-buffered and would otherwise stay empty);
* ad-hoc signs the bundle (`codesign --sign -`) so macOS treats it as one app.

Notes:

* The bundle is a **launcher**, not a copy: edits to this checkout are live on the
  next launch. The first launch is slow (Julia JIT); later ones reuse the cache.
* Panes still get the clean environment (the app's project is never inherited).
* **Local Network (ssh to LAN/link-local hosts) is blocked in a Finder-launched
  bundle** unless macOS grants the app permission: `nc` to `169.254.x`/`192.168.x`
  fails with "No route to host" inside the app while the same command works from
  Terminal. macOS 14+ only *offers* that permission to a properly signed app, so
  either sign with an identity (`scripts/buildMacApp.sh --identity "Developer ID
  Application: …"` or an Apple Development cert) and grant it under System
  Settings → Privacy & Security → Local Network, or launch from Terminal
  (`~/Applications/Flooty.app/Contents/MacOS/Flooty`, or `flooty`)
  where the panes inherit Terminal's grant.
* To share it with other Macs you need a Developer ID signature and notarization
  (`xcrun notarytool submit … --wait`, then `xcrun stapler staple`); an ad-hoc
  bundle is blocked by Gatekeeper elsewhere.
* **Self-contained** (no Julia install, no checkout, fast start): use
  PackageCompiler — not wired into this repo because it builds a sysimage and must
  be re-run after every dependency change:

  ```julia
  using PackageCompiler
  create_app("Flooty", "Flooty.app";
             executables = ["Flooty" => "main"],   # Flooty.@main
             app_name = "Flooty",
             icon = "assets/flooty-icon.icns",
             force = true)
  ```

  (Generate the `.icns` with `scripts/buildMacApp.sh` and copy it from the bundle's
  `Contents/Resources`.)

## License

MIT License — see `Project.toml` for details.
