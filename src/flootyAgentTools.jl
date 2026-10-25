# flootyAgentTools.jl — typed terminal-use tools over FlootyPTYLayer's
# ReplSession (Warp terminal-use style ownership rules).
#
# Works identically for headless sessions and UI-attached ones: the WebView UI
# creates its own ReplSession-shaped entries; agent tools only need the PTY +
# control machine, which both expose.

using FlootyPTYLayer

"""
Who owns input right now (mirrors Warp's TuiInputTarget):
- `agentEditor`: prompt idle → agent may act.
- `ptyOwns`:     a foreground process/eval is running or the user holds the
                 REPL (`:user` control state) → agent yields.
- `disabled`:    session closed / PTY dead → nothing may write.
"""
@enum InputTarget inputDisabled inputPtyOwns inputAgentEditor

"""
    inputTargetFor(sess) -> InputTarget

Arbitrate who owns input for this session right now. The user's control state
(`tagOut` → `:user`) always beats the agent; a running eval shows up as an
executing control state via the registry's pending set.
"""
function inputTargetFor(sess::ReplSession)
    sess.closed || sess.pty.open || return inputDisabled
    currentState(sess.control) == :user && return inputPtyOwns
    pendingCount = lock(() -> length(sess.pending), sess.lock)
    pendingCount > 0 && return inputPtyOwns
    return inputAgentEditor
end

"""
Snapshot of everything the LLM sees in one turn — small enough for local
context windows: recent output tail, control state, last eval outcomes.
"""
Base.@kwdef struct TerminalSnapshot
    atPrompt::Bool
    controlState::Symbol
    outputTail::String
    lastOutcomes::Vector{String}
    rows::Int = 24
    cols::Int = 80
    # Which REPL mode the foreground prompt is in (`:julia`, `:shell`, `:pkg`,
    # `:help`, `:unknown`): a `send` means something different in each, so the
    # model must see it before choosing what to type.
    mode::Symbol = :unknown
    # Shell PS2 state (heredoc/quote/cmdsubst). Explicit so stale scrollback
    # cannot make the model assume a continuation is still open.
    ps2::Bool = false
    # Lines that scrolled ABOVE the visible window (what the user can scroll to).
    # The report carries them (bounded); `scrollback_truncated` says older lines
    # were left out, which is the agent's cue to PAGE rather than guess.
    scrollback_rows::Int = 0
    scrollback_truncated::Bool = false
    # Text typed at the prompt but not submitted (kept OUT of atPrompt: sending
    # would append to it). Shown to the model so it can clear or submit it.
    inputLine::String = ""
    # The foreground app owns the screen (alternate screen: pager, editor, TUI).
    # No prompt exists, so `send` is refused: interact with `{"action":"type"}`.
    fullscreen::Bool = false
    # The PTY size a program set with `stty` (0 = same as the pane). Reported when
    # it differs, so the model knows output wraps at the PANE width.
    pty_rows::Int = 0
    pty_cols::Int = 0
    # An interactive command is STILL RUNNING and the pane is not at a prompt.
    # This is the signal that works for pagers that do not use the alternate
    # screen (a `bat`/`less` variant that paints inline): the agent must send
    # KEYS (`type`), not more commands.
    appRunning::Bool = false
    # The TEMPORARY split child of this pane, if one is open. The main driver
    # must know it exists (and whether the USER is typing there) before it
    # decides the user is idle.
    split_open::Bool = false
    split_id::String = ""
    split_input::String = ""
    split_count::Int = 0
    split_list::String = ""
    # ALL child sessions (split panes, terminal tabs, chat tabs), creation
    # order; the loop's child:N targets index the terminal ones.
    child_count::Int = 0
    child_list::String = ""
end

function Base.string(s::TerminalSnapshot)
    io = IOBuffer()
    println(io, "terminal=", s.rows, "x", s.cols, " mode=", s.mode,
            " controlState=", s.controlState, " atPrompt=", s.atPrompt,
            " ps2=", s.ps2)
    if !isempty(s.inputLine)
        println(io, "input=", repr(s.inputLine),
                " (text is already typed at the prompt: submit with ",
                "{\"action\":\"type\",\"keys\":\"\\r\"}, clear with ",
                "\"\\x15\" (Ctrl-U) or \"\\x03\" (Ctrl-C) before sending)")
    end
    if s.pty_rows > 0 && (s.pty_rows != s.rows || s.pty_cols != s.cols)
        println(io, "pty=", s.pty_rows, "x", s.pty_cols,
                " differs from the pane (a program changed stty; output wraps at ",
                "the pane width)")
    end
    if s.fullscreen || s.appRunning
        println(io, "screen=", s.fullscreen ? "fullscreen" : "app-running",
                " (no prompt: use {\"action\":\"type\"} keys — space/PgDn to page, " *
                "q to quit; `send` is refused here)")
    end
    if s.child_count > 0
        println(io, "children=", s.child_count, ": ", s.child_list)
    end
    if s.split_open
        println(io, "split=open (", s.split_count, " child",
                s.split_count == 1 ? "" : "ren", ": ", s.split_list,
                ") — TEMPORARY second pane(s); target=\"split\" (newest) or " *
                "\"split:N\"; closeSplit when done")
    end
    if s.scrollback_rows > 0
        println(io, "scrollback=", s.scrollback_rows, " lines above the viewport",
                s.scrollback_truncated ?
                    " (NOT included — page them: " *
                    "bat --paging=always --pager=less FILE, " *
                    "or bat --paging=never FILE)" : " (included above)")
    end
    if !isempty(s.lastOutcomes)
        println(io, "recentEvals:")
        for line in s.lastOutcomes[1:min(end, 5)]
            println(io, "  ", line)
        end
    end
    print(io, "outputTail:\n", s.outputTail)
    return String(take!(io))
end

"""
    _lineAlignedTail(text, maxChars) -> String

The LAST ≤maxChars of `text`, but starting at a LINE BOUNDARY. A hard cut
through a sentinel echo line leaves an orphaned half-tag that no scrubber
recognizes afterwards (the leak seen as `L_BEGIN:", "eval000001")` at the
head of agent snapshots). Cutting FIRST on line boundaries and THEN scrubbing
ever yields whole lines to the scrubber.
"""
function _lineAlignedTail(text::AbstractString, maxChars::Int)
    length(text) <= maxChars && return text
    cut = prevind(text, min(lastindex(text), length(text) - maxChars + 1))
    # First newline AT OR AFTER the ideal cut ⇒ result is strictly SHORTER
    # than maxChars and starts on a clean line boundary.
    nl = findnext('\n', text, cut)
    nl === nothing && return last(text, prevind(text, lastindex(text), maxChars))
    return SubString(text, nextind(text, nl))
end

# Full display-safety pipeline for anything handed to the model: ANSI off,
# bare \r dropped (REPL prompt redraws render as garbage line-breaks
# otherwise), sentinel LINES blanked, THEN residual orphans handled:
#   * a head ORPHAN (`L_BEGIN:", "eval000001")` — tag half cut away by a
#     hard excerpt cut) is stripped ONLY up to the end of the bookkeeping
#     call; real output that shares its row (the echo of what ran) survives;
#   * a whole surviving line that is JUST an eval-id echo is blanked;
#   * a TRAILING partial tag (excerpt cut mid-word, e.g. …FLOOTY_EVAL_BEG)
#     is trimmed off the end.
# Orphans carry zero information and one glimpse is what taught models to
# emit their own sentinels.
function cleanSnapshotText(text::AbstractString)
    clean = replace(
        FlootyPTYLayer.scrubSentinelLines(ansiStrip(text)), '\r' => "")
    clean = replace(clean, string(Char(0xf0a7)) => "")
    # Head orphan: everything from line start through `…evalNNNNNN")` goes,
    # whatever follows on that line stays. (?m) makes ^ anchor at line starts.
    clean = replace(clean, r"(?m)^[^\n\r]*?\"eval\d{6}\"[^\n\r]*?\)" => "")
    # Whole-line eval-id echo with NO closing call: blank just that line.
    clean = replace(clean, r"(?m)^[^\n\r]*\"eval\d{6}\"[^\n\r]*$" => "")
    # Unquoted bare id (echo lost its quotes): same whole-line rule.
    clean = replace(clean, r"(?m)^[^\n\r]*\beval\d{6}\b[^\n\r]*$" => "")
    # Trim a trailing partial prefix of "FLOOTY_EVAL_" (excerpt cut mid-word):
    # only when the last k chars contain NO newline (else it's real content).
    maxK = min(length(clean), length(FlootyPTYLayer.SENTINEL_TAG) - 1)
    for k in maxK:-1:6
        tailPart = String(last(clean, k))
        if !occursin('\n', tailPart) && !occursin('\r', tailPart) &&
           startswith(FlootyPTYLayer.SENTINEL_TAG, tailPart)
            return String(first(clean, length(clean) - k))
        end
    end
    return clean
end

"""
    atIdlePrompt(sess, tail = tailText) -> Bool

Shell-aware prompt check: a bare `>` is bash/zsh PS2 (heredoc/quote
continuation) for a shell session, but it IS the prompt of a Node REPL.
"""
function atIdlePrompt(sess, tailStr::AbstractString =
                          FlootyPTYLayer.tailText(sess.tail))
    shell = try FlootyPTYLayer.sessionKind(sess) == :shell catch; false end
    return FlootyPTYLayer._tailAtIdlePrompt(tailStr; bare_gt = !shell)
end

"""
    agentSnapshot(sess; tailChars = 0, historyN = 5) :: TerminalSnapshot

Collect current state + recent output for the model. The output tail is the
RENDERED xterm viewport of this session when a UI window is attached (the
screen the user actually sees, right-trimmed, escape sequences already
interpreted), and the END of the raw rolling output buffer otherwise. Either
way it is cut on a LINE boundary before scrubbing so sentinel echo lines are
never sliced mid-tag (see `_lineAlignedTail`).

`tailChars = 0` (the default) passes the terminal's content AS IT IS — no budget,
no slicing: the model sees exactly the buffer the user sees. A positive
`tailChars` is an explicit caller cap (the ambient monitor uses one); the agent
loop never passes one.
"""
function agentSnapshot(sess::ReplSession; tailChars::Int = 0,
                       historyN::Int = 5)
    ptyRows, ptyCols = FlootyPTYLayer.ptyWinsize(sess.pty)
    vmeta0 = try
        FlootyPTYLayer.terminalViewportMeta(sess)
    catch
        nothing
    end
    # The PANE is what the user sees: prefer its real grid over a PTY size a
    # program changed with `stty` (that mismatch made the model misread wrapping).
    rows = vmeta0 === nothing || vmeta0.rows <= 0 ? ptyRows : Int(vmeta0.rows)
    cols = vmeta0 === nothing || vmeta0.columns <= 0 ? ptyCols : Int(vmeta0.columns)
    # NO BUDGET by default (tailChars = 0): the snapshot is the full rendered
    # buffer. Optimising this comes LATER; cutting it first made the model's view
    # diverge from the user's.
    budget = tailChars
    # FRESHNESS: a snapshot is taken right after one of the agent's own commands,
    # which is exactly when the page's debounced (120 ms) viewport push has not
    # fired yet — the model then reads the screen from BEFORE its command and can
    # repeat an edit whose result is already on screen. Ask for an immediate
    # report when a window holds this session (bounded wait, cheap); otherwise
    # use the cached report.
    screen = FlootyPTYLayer.activeTerminalUiWebview() === nothing ?
             FlootyPTYLayer.terminalBufferFor(sess) :
             FlootyPTYLayer.pushTerminalBuffer!(sess; waitS = 0.4)
    raw = isempty(screen) ? FlootyPTYLayer.tailText(sess.tail) : screen
    # With a caller cap, cut on a LINE boundary so sentinel echo lines are never
    # sliced mid-tag (see _lineAlignedTail); without one, use the text unchanged.
    tailTextStr = budget > 0 ? String(_lineAlignedTail(raw, budget)) : String(raw)
    hist = sessionHistory(sess; n = historyN)
    outcomes = String[]
    for h in hist
        push!(outcomes, string(h.ok ? "ok" : "ERR", " ", h.errorKind, " ",
                               round(h.duration; digits = 2), "s"))
    end
    target = inputTargetFor(sess)
    tailNow = FlootyPTYLayer.tailText(sess.tail)
    promptNow = atIdlePrompt(sess, tailNow)
    # A full-screen app (pager/editor/TUI) leaves an OLD prompt line at the tail's
    # end while it owns the screen, so the glyph test alone says "at a prompt".
    # `send` must be refused there: the keys belong to the app (`type`).
    appOwns = (try
        FlootyPTYLayer.inAltScreen(sess)
    catch
        false
    end) || FlootyPTYLayer._tailLooksLikeApp(tailNow)
    # LEFTOVER INPUT BLOCKS send: a stray key press leaves text on the prompt line
    # and a send would APPEND to it (observed: `q` + `echo x` ran `qecho x`).
    pending = try
        FlootyPTYLayer.pendingInputLine(sess)
    catch
        ""
    end
    atPrompt = target == inputAgentEditor && promptNow && isempty(pending) && !appOwns
    vmeta = vmeta0
    splitKids = try
        FlootyPTYLayer.splitChildren(sess)
    catch
        ReplSession[]
    end
    splitKids = [k for k in splitKids if !k.closed]
    splitOpen = !isempty(splitKids)
    splitSess = splitOpen ? splitKids[end] : nothing
    splitId = splitSess === nothing ? "" : FlootyPTYLayer.sessionIdFor(splitSess)
    splitInput = ""
    splitRows = String[]
    for (i, k) in enumerate(splitKids)
        pend = try
            FlootyPTYLayer.pendingInputLine(k)
        catch
            ""
        end
        i == length(splitKids) && (splitInput = pend)
        push!(splitRows, string("[", i, "] ", first(FlootyPTYLayer.sessionIdFor(k), 8),
                                " input=", repr(pend)))
    end
    splitList = join(splitRows, "; ")
    childNodes = try
        childSessions(sess)
    catch
        Any[]
    end
    childRows = String[]
    for (i, c) in enumerate(childNodes)
        if c isa TerminalSession
            pend = try
                FlootyPTYLayer.pendingInputLine(c.repl)
            catch
                ""
            end
            pres = try
                FlootyPTYLayer.splitParentSession(c.repl) === nothing ? "tab" : "split"
            catch
                "?"
            end
            push!(childRows, string("[", i, "] terminal/", pres, " id=",
                                    first(c.id, 8), " input=", repr(pend)))
        elseif c isa ChatSession
            push!(childRows, string("[", i, "] chat id=", first(c.id, 8)))
        end
    end
    childList = join(childRows, "; ")
    return TerminalSnapshot(
        pty_rows = (rows == ptyRows && cols == ptyCols) ? 0 : ptyRows,
        pty_cols = (rows == ptyRows && cols == ptyCols) ? 0 : ptyCols,
        atPrompt = atPrompt,
        ps2 = try
            FlootyPTYLayer.shellAtPS2(sess)
        catch
            false
        end,
        mode = try
            FlootyPTYLayer.replMode(sess)
        catch
            :unknown
        end,
        fullscreen = try
            FlootyPTYLayer.inAltScreen(sess)
        catch
            false
        end,
        appRunning = !atPrompt && (try
            lastKind = FlootyPTYLayer.sessionHistory(sess; n = 1)
            !isempty(lastKind) && lastKind[1].errorKind == :running &&
                currentState(sess.control) != :user
        catch
            false
        end),
        scrollback_rows = vmeta === nothing ? 0 : Int(vmeta.scrollback_rows),
        scrollback_truncated = vmeta === nothing ? false : Bool(vmeta.scrollback_truncated),
        controlState = currentState(sess.control),
        inputLine = pending,
        outputTail = strip(cleanSnapshotText(tailTextStr)),
        lastOutcomes = outcomes,
        rows = rows,
        cols = cols,
        split_open = splitOpen,
        split_id = splitId,
        split_input = splitInput,
        split_count = length(splitKids),
        split_list = splitList,
        child_count = length(childNodes),
        child_list = childList,
    )
end

# ---- provider tool-call markup ------------------------------------------------
# Beam (and models like it) sometimes answer a "you have tools" prompt with their OWN
# tool-call syntax instead of our JSON protocol:
#
#     <rfl:parameter name="code">names(WGPUCompute, all=true)</rfl:parameter>
#
# Left alone that line does two bad things: it lands in the chat as gibberish, and
# the loop sees no action and stops as "unparseable" — so the terminal never runs
# anything. These helpers hide it from the UI and translate it into our protocol.
const PROVIDER_CALL_NS = "(?:[A-Za-z_][A-Za-z0-9_]*:)?"

"""
    stripInvisible(text) :: String

Remove the INVISIBLE characters models slip into markup: zero-width space/joiners,
word joiner and BOM. Observed live: a close tag arrived as `<\\u200b/rfl:parameter>`,
which defeated every markup regex and turned a plain command into "unparseable".
"""
stripInvisible(text::AbstractString) =
    replace(String(text), r"[\u200b\u200c\u200d\u2060\ufeff]" => "")
const PROVIDER_PARAMETER_RE = Regex(
    "<\\s*" * PROVIDER_CALL_NS * "(?:parameter|argument)\\b[^>]*>" *
    ".*?" *
    "</\\s*" * PROVIDER_CALL_NS * "(?:parameter|argument)\\s*>",
    "si")
const PROVIDER_OPEN_RE = Regex("<\\s*" * PROVIDER_CALL_NS *
                               "(?:parameter|argument|invoke|tool_call|function_call)\\b[^>]*>",
                               "si")
const PROVIDER_CLOSE_RE = Regex("</\\s*" * PROVIDER_CALL_NS *
                                "(?:parameter|argument|invoke|tool_call|function_call)\\s*>",
                                "si")
const PROVIDER_NAME_RE = Regex("name\\s*=\\s*[\"']([^\"']+)[\"']", "i")

"""
    providerParameters(text) :: Vector{Tuple{String,String}}

Every `<…:parameter name="X">body</…:parameter>` pair in `text` (the wrapper tags are
ignored). Empty when the reply used our JSON protocol or plain prose.
"""
function providerParameters(text::AbstractString)::Vector{Tuple{String,String}}
    text = stripInvisible(text)
    out = Tuple{String,String}[]
    for m in eachmatch(Regex("<\\s*" * PROVIDER_CALL_NS *
                             "(?:parameter|argument)\\b([^>]*)>(.*?)</\\s*" *
                             PROVIDER_CALL_NS * "(?:parameter|argument)\\s*>", "si"),
                       String(text))
        name = match(PROVIDER_NAME_RE, m.captures[1])
        name === nothing && continue
        body = strip(String(m.captures[2]))
        push!(out, (lowercase(name.captures[1]), body))
    end
    return out
end

"""
    stripProviderMarkup(text) :: String

`text` without any provider tool-call markup: what the USER should see. Leaves the
surrounding prose intact and drops the blank lines the removal leaves behind.
"""
function stripProviderMarkup(text::AbstractString)::String
    out = replace(stripInvisible(text), PROVIDER_PARAMETER_RE => "")
    out = replace(out, PROVIDER_OPEN_RE => "")
    out = replace(out, PROVIDER_CLOSE_RE => "")
    out = replace(out, r"(?m)^\s*$\n" => "")
    return strip(out)
end

"""
    extractProviderAction(text) :: Union{Nothing,Dict{String,Any}}

Our action for a reply written in a provider's tool-call syntax, or `nothing` when
the reply carries none. Mapping (the parameter names those models use):

| parameter                          | action                        |
| `code`, `command`, `statement`, `input` | `send`                    |
| `keys`, `keystrokes`               | `type`                        |
| `seconds`, `wait` (numeric)        | `wait`                        |
| `summary`                          | `done`                        |

The first recognized parameter wins; unknown names are ignored rather than guessed.
"""
function extractProviderAction(text::AbstractString)::Union{Nothing,JSON3.Object}
    text = stripInvisible(text)
    params = providerParameters(text)
    if isempty(params)
        # TRUNCATED markup: `<rfl:parameter name="code">ls -la` with no close tag.
        m = match(Regex("<\\s*" * PROVIDER_CALL_NS *
                        "(?:parameter|argument)\\b([^>]*)>(.*)\\z", "si"), String(text))
        if m !== nothing
            nm = match(PROVIDER_NAME_RE, m.captures[1])
            nm !== nothing && !isempty(strip(m.captures[2])) &&
                push!(params, (lowercase(nm.captures[1]), strip(String(m.captures[2]))))
        end
    end
    for (name, body) in params
        isempty(body) && continue
        dict = if name in ("code", "command", "statement", "input", "cmd")
            Dict{String,Any}("action" => "send", "code" => body)
        elseif name in ("keys", "keystrokes", "key")
            Dict{String,Any}("action" => "type", "keys" => body)
        elseif name in ("seconds", "wait", "timeout")
            value = tryparse(Float64, body)
            value === nothing ? nothing :
                Dict{String,Any}("action" => "wait", "seconds" => value)
        elseif name in ("summary", "answer", "result")
            Dict{String,Any}("action" => "done", "summary" => body)
        else
            nothing
        end
        dict === nothing && continue
        # Return the SAME type the JSON path returns: every downstream helper
        # (`getstr`, `get`) is written against a JSON3.Object, and a plain Dict made
        # the dispatch read an empty action ("unknown action ''" — the call was
        # translated and then silently dropped).
        return JSON3.read(JSON3.write(dict))
    end
    return nothing
end

# Minimal ANSI escape stripper so snapshots don't burn tokens on color codes.
# NOTE: the CSI pattern requires a LETTER terminator, so bracketed-paste
# sequences (\e[200~/\e[201~) match it — but multi-line pastes echoed back
# can arrive SPLIT across chunk boundaries, leaving orphan fragments that
# render as stray characters in the snapshot (the mysterious leading "C" and
# trailing "~" seen around agent-typed for-loops). Strip those explicitly.
function ansiStrip(s::AbstractString)
    out = replace(String(s), r"\x1b\[[0-9;?]*[A-Za-z]" => "",
                  r"\x1b\][^\x07]*\x07" => "", r"\x1b[=>]" => "")
    out = replace(out, r"\x1b\[\??(200|201)~" => "")
    out = replace(out, r"(?<!\x1b\[)[0-9]{2,3}(200|201)~" => "")   # split heads
    return replace(out, r"\e." => "")                                # leftover escapes
end

"""
    agentSendStatement!(sess, code; timeoutS = 60.0) ->
        (ok::Bool, excerpt::String)

Send one statement as the AGENT through the duplex loop and wait for its
END sentinel. Errors when the user currently owns the REPL (`inputPtyOwns`
with `:user` control state) — that's the ownership contract; callers should
snapshot first and wait or ask.
"""
function agentSendStatement!(sess::ReplSession, code::AbstractString;
                             timeoutS::Real = 60.0,
                             poll::Union{Nothing,Function} = nothing)
    target = inputTargetFor(sess)
    if target != inputAgentEditor
        return (false, "agent yield: input owned by " *
                       (target == inputPtyOwns ? "terminal/user" : "nothing") *
                       " (controlState=$(currentState(sess.control)))")
    end
    outcome = agentWriteAndWait(sess, String(code); timeout = Float64(timeoutS),
                                poll = poll)
    return outcome.ok ? (true, outcome.excerpt) : (false, outcome.excerpt)
end

"""
    agentInterject!(sess, reason = ""; force = false) ->
        (sent::Bool, detail::String)

Send Ctrl+C into the PTY to interrupt whatever runs. Warp-style gating:
only allowed while the agent legitimately holds the loop (`:agent` /
`:shared`, e.g. it started the long-running statement itself) or when
`force=true` — the explicit "user-approved interrupt" path surfaced by the
monitor popup flow. User-owned runs are NEVER auto-interrupted.
"""
function agentInterject!(sess::ReplSession, reason::AbstractString = "";
                         force::Bool = false)
    sess.closed && return (false, "session closed")
    sess.pty.open || return (false, "pty closed")
    state = currentState(sess.control)
    if !force && state == :user
        return (false, "interrupt refused: user owns the session")
    end
    writeToPty(sess.pty, Vector{UInt8}(codeunits("\u0003")); source = :agent)
    detail = isempty(reason) ? "Ctrl+C sent" : "Ctrl+C sent ($reason)"
    return (true, detail)
end

