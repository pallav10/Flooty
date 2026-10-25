# flootyAgentLoop.jl — the option-2 core: an autonomous local-model loop that
# drives a live ReplSession. Each turn: snapshot → LLM → one structured action.
#
# Action protocol (JSON in the assistant content, no native tool-calling
# required — works with ANY model incl. thinking variants after stripThinking):
#   {"action":"send",      "code":"println(1+1)", "expect":"optional note",
#                           "target":"main|split"}
#   {"action":"wait",      "seconds":2}
#   {"action":"interrupt", "reason":"runaway loop"}   (agent-owned runs only)
#   {"action":"feedback",  "title":"...", "body":"...", "kind":"info|warn|interrupt"}
#   {"action":"done",      "summary":"..."}
# Malformed output is treated as a wait-and-retry, never a crash.

using FlootyPTYLayer

# One `send` may not carry an unbounded command: past this the model is writing a
# multi-hundred-line pipeline in a single JSON string, which the provider truncates
# (observed: an unterminated `code` value, three strikes, run stopped). Chunking is
# also what keeps the screen readable for the next turn.
const SEND_MAX_CODE_CHARS = 3000

# Repeated immediately before every completion: the system prompt is at the top
# of a long context and weak drivers bury it. This is the minimal operational
# rule for a viewport-limited terminal harness.
const AGENT_TURN_REMINDER = """
HARNESS REMINDER: this is a TERMINAL-USE harness. The snapshot is only the
visible VIEWPORT; output that leaves the screen does not come back by itself.
For long output open an INTERACTIVE PAGER: `bat FILE`, `git log`, `less FILE`.
START it with `type` (command + newline), never `send`. `type` space for the
next page, `b` back, `/` search, `q` quit; `wait` after each key. A pager holds
its output and shows one screen at a time; quit it before the next action.
Never `cat` a whole file.
"""

# A full-screen app needs a beat to enter RAW mode; until it does, the line
# discipline may (a) interpret/mangle keys and (b) flush pending input when the
# app switches modes. Typing immediately after launch lost the whole story.
const TYPE_SETTLE_S = 0.35
# How long a pager/editor gets to hand the pane back after its quit key.
const TYPE_QUIT_TIMEOUT_S = 2.5

"""Agent feedback event handed to `onEvent` callbacks and the UI popup bridge.
`sessionId` tags the event with the OWNING session's terminal id so the page
decides which tab displays the popup — concurrent per-session agents never
cross-pollinate each other's tabs ("" = legacy broadcast)."""
Base.@kwdef struct AgentFeedback
    title::String
    body::String
    kind::String = "info"        # info | warn | interrupt
    sessionId::String = ""
end

"""
    AgentLoopResult

Final state of one `runAgentLoop!` invocation.
"""
Base.@kwdef mutable struct AgentLoopResult
    ok::Bool = false
    turns::Int = 0
    summary::String = ""
    transcript::Vector{String} = String[]
end

const AGENT_SYSTEM_PROMPT = """
You are Flooty, an agent that drives a live TERMINAL (generic model — usually
the user's interactive shell; REPLs like julia may be running inside it).
Each turn you receive a terminal snapshot; reply with EXACTLY ONE JSON object
and nothing else (no markdown fence):
{"action":"send","code":"<one shell command or statement>"}   run it now
{"action":"type","keys":"<raw bytes>"}   type keys without waiting (pagers, editors, REPL switches)
{"action":"parallel","sends":[{"target":"main|child:N","code":"…"},…]}  one send per DISTINCT session, concurrently
{"action":"newTerminal","reason":"<why another pane>"}   open a new terminal tab
{"action":"splitTerminal","reason":"<why a child>","orientation":"vertical|horizontal"}  open a CHILD SESSION of this one
{"action":"newChat","reason":"<why a new conversation>"}  open a CHILD chat session in its own tab
{"action":"closeSplit"}                              close the child pane(s) when done
{"action":"compact"}                                 fold older turns away (context nearly full)
{"action":"wait","seconds":<n>}                      let output settle (<=5)
{"action":"feedback","title":"<t>","body":"<b>","kind":"info|warn|interrupt"}
{"action":"done","summary":"<what was accomplished>"}
CONTEXT BUDGET: each turn's status line reports the estimated context usage
(`ctx 12.3k/1M (1%)`). Near the window limit the loop compacts automatically by
folding older turns into a digest; you can ask for that early with
{"action":"compact"} (the snapshot is always fresh, so re-derive state from it).
TERMINAL-USE HARNESS: each snapshot is exactly the rows x columns currently
visible. Output that leaves the screen is not shown to you again; a command that
prints too much hides its own beginning.
INTERACTIVE PAGER: for a long output, use a pager: `bat FILE`, `git log`,
`git --paginate log`, or `less FILE`. The pager holds the output and shows ONE
SCREEN at a time. START it with `type` (`"keys":"git log\\n"`), never with
`send` — `send` waits for a shell prompt that is hidden while the pager is open.
Then `type` space = next page, `b` = previous, `/` = search, `q` = quit, and
`wait` after each key. NEVER leave a pager open; return to the shell prompt
with `q` before the next action. Do not use `--no-pager`/`--paging=never` for a
long output — the interactive pager is the intended view.
SMALL READS: for a known small range, `sed -n 'A,Bp' FILE`, `head -n N`,
`tail -n N`, `grep -n`, or `wc -l` is fine.
FILE READS: never `cat` a whole file or dump a whole output.
LARGE REPO TASKS: prefer bounded reconnaissance. Read the README, manifest, entry point and
a few representative files, list the tree, then commit to a minimal plan and
START WRITING. Do not read every source file line by line, and do not re-read a
file you have already seen. For a port request, build one working vertical slice
first rather than surveying the whole repository. If the user asks for a
"Julia version" (or another language), create the package skeleton (Project.toml,
entry module, tests) and port one small subsystem; do not end at feasibility
notes or reconnaissance.
REPL MODES (the snapshot's `mode=` says which one is live): `julia>` runs Julia,
`shell>` runs ONE external command through Julia's own shell parser — it is NOT
zsh: `|`, `&&`, `;`, `>`/`2>` are typed as ARGUMENTS, not operators (observed:
`find … | sort` → `find: |: unknown primary or operator`). Use one command per
send there, or switch back to `julia>` (`\x7f`) and compose with
`run(pipeline(`a`, `b`))`. `(@v1.x) pkg>` runs Pkg commands, `help?>` searches
help. `send` runs the line in the CURRENT mode — a Julia statement typed at
`pkg>` is a Pkg error, not Julia. Switch with {"action":"type","keys":";"} (shell),
"]" (pkg), "?" (help), "\x7f" (backspace: back to julia>); a `send` of a bare
";", "]", "?" or "\x7f" switches too (no Enter is typed).
Rules: `code` is ONE line for a POSIX shell (pipe/&& for composition) — or,
when a julia/python-style REPL is visibly at the prompt (see outputTail), one
statement in THAT language — for `send`. Use `type` for any interactive or
full-screen program (micro, vim, nano, python, julia itself): type the raw
bytes (including Enter), then `wait` for the application's own input prompt.
`send` must be a COMPLETE one-line command. If it would leave the shell at a
continuation (unclosed quote or heredoc, trailing `&&`/`|`/backslash), the
harness refuses it before typing and returns an incompleteInput result. Use
`type` for multi-line or interactive input, then `wait`.
Never send again while atPrompt=false. Finish with done IMMEDIATELY when the
task is complete or clearly impossible — NEVER pad the conversation with
feedback/wait turns once nothing is left to do. If the last ACTION RESULT
was ERROR, your next command MUST differ.
READ FILES THROUGH THE TERMINAL, preferring a pager you can drive:
- shell/SSH: `bat --paging=always --pager=less FILE` opens the file in the
  pane. Scroll with {"action":"type"} space/PgDn, quit with q, then wait until
  atPrompt=true. For a non-interactive bounded view use `bat --paging=never FILE`
  (or `head`/`tail`/`sed -n 'A,Bp'`) and read the result from outputTail.
- Julia REPL (`julia>`): prefer TerminalPager when available:
  {"action":"send","code":"using TerminalPager; pager(read(\"FILE\", String))"}
  then type space/PgDn and q. If it is not installed, read a bounded slice with
  Julia (`eachline`/`readlines` with a range) or switch to the shell for bat/sed.
Never dump a whole large file; the snapshot is the viewport and earlier lines are
GONE from it. On an SSH pane these commands run on the remote host.
SHOWING THE USER: printed output is what the pane shows, and the user sees the
SAME viewport you do. For a long result, print bounded excerpts; when a human
must inspect it interactively, page it DELIBERATELY with
`bat --paging=always --pager=less FILE`, then {"action":"type"} space/PgDn,
`q`, and `wait` for atPrompt=true. Never leave a pager open at done.
PAGERS: `bat FILE` (without `--paging=never`), `less`, `more`, `man` take over
the screen and wait for keys — a `send` of one is reported as STARTED and the
snapshot then says `screen=fullscreen`. NO prompt exists there, so `send` is
refused: use {"action":"type"} with space/PgDn to page and "q" to quit — and
`wait` until the snapshot shows atPrompt=true again before sending a command
(keys typed before the pager reads input land in the shell instead). On THIS
machine plain `bat FILE` prints and exits (its config pages with `cat`), so keys
sent to page it land at the SHELL; page deliberately with the `--paging=always`
form above. Or avoid pagers entirely (`bat --paging=never`, `sed -n 'A,Bp'`).
Interactivity: applications do not produce an eval result; read outputTail each
turn before typing the next keystroke (e.g. Ctrl+S or Ctrl+Q in micro). Use `stty size`
(or `tput cols` and `tput lines`) to learn terminal dimensions when formatting output.
Output you PRINT is what the pane shows and what comes back in outputTail on the
NEXT turn's snapshot: `println`/`print`/`echo` is the only way to inspect a value
mid-run, and it is how the user watches you work. Your own words reach the user
through `done` and `feedback`, not through the terminal.
CHILD SESSIONS: a child terminal and a child chat are CHILD SESSIONS of this
one. The snapshot's `children=` line lists them in creation order, and they
are addressed UNIFORMLY with {"action":"send","code":"…","target":"child:N"}.
`splitTerminal` and `newTerminal` open a child terminal session; `newChat`
opens a child chat session. `closeSplit` closes the child sessions. The app
shows ONE session at a time, so a child is a node of the session tree (the
user switches to it) — not a pane beside this one. Each child has its own
monitor; its user-intent insights arrive as MONITOR NOTEs, and the snapshot
lists each child's pending input. Check `children=` before assuming the user
is idle. Do not use them as permanent workspaces.
Without "target" (or with "main") the command goes to the pane you were
commissioned in.
PARALLEL: use {"action":"parallel"} only for INDEPENDENT work in DIFFERENT panes
(one build in main, one test in child:1, one in child:2). Each pane gets at most
one send; targets are main, child:N (split or terminal tab), or the split alias;
results arrive together. Never batch two commands that touch the same
file or depend on each other, and never batch an interactive program.
Inside JSON string values ALWAYS escape quotes as \\\" and newlines as \\n.
For {"action":"type"} the keys are escapes too: Enter = \\r, Ctrl-C = \\x03, Esc = \\x1b, Tab = \\t, and a literal backslash is \\\\.
A pager/editor is quit with `q` (pager) or its own binding (micro: Ctrl-Q = \\x11).
NEVER print, echo, or re-create anything containing FLOOTY_EVAL or private-use
marker characters (\uf0a7) — those are internal bookkeeping of this harness;
if remnants appear in output, IGNORE them entirely.
"""

"""
Extract the FIRST BALANCED `{...}` CANDIDATE that parses as JSON AND carries
an `action` key. Weak models wrap the payload in prose (“the output {INTENT_42}
shows…”), so giving up on the first non-parsing candidate made every such
reply “unparseable” forever. Instead: scan candidate objects left-to-right,
skip the ones that don't parse / lack `action`, and only fail when exhausted.
Returns JSON3.Object or nothing.

Near-miss REPAIR: weak models emit pretty-printed objects whose string
values contain LITERAL newlines/tabs (strictly invalid JSON — observed live:
granite4's done summaries span lines). Candidates are re-parsed once with
raw control chars inside string literals escaped; typographic quotes get
straightened as a last resort.
"""
function extractActionJson(text::AbstractString)
    s = String(text)
    pos = firstindex(s)
    while true
        st = findnext('{', s, pos)
        st === nothing && return nothing
        depth = 0
        inStr = false
        esc = false
        closeIdx = 0
        k = st
        while k <= lastindex(s)
            c = s[k]
            if inStr
                if esc
                    esc = false
                elseif c == '\\'
                    esc = true
                elseif c == '"'
                    inStr = false
                end
            elseif c == '"'
                inStr = true
            elseif c == '{'
                depth += 1
            elseif c == '}'
                depth -= 1
                if depth == 0
                    closeIdx = k
                    break
                end
            end
            k = nextind(s, k)
        end
        closeIdx == 0 && return nothing     # truncated JSON — nothing more to try
        parsed = _tryParseActionCandidate(s[st:closeIdx])
        parsed !== nothing && return parsed
        pos = nextind(s, closeIdx)          # skip past this candidate, keep scanning
    end
end

"""
    jsonFailureKind(text) :: Symbol

WHY a reply did not parse, so the corrective note can name the actual mistake
instead of repeating one generic sentence:

  * `:prose`     — no `{` at all (the model answered in words);
  * `:truncated` — a candidate opened but never closed (output cut mid-command,
    e.g. a long `code` value hitting the provider's output cap);
  * `:malformed` — a balanced candidate that still does not parse (unterminated
    string at the close, bad escape, wrong shape).
"""
function jsonFailureKind(text::AbstractString)::Symbol
    s = String(text)
    st = findfirst('{', s)
    st === nothing && return :prose
    depth = 0
    inStr = false
    esc = false
    for c in s[st:end]
        if inStr
            if esc
                esc = false
            elseif c == '\\'
                esc = true
            elseif c == '"'
                inStr = false
            end
        elseif c == '"'
            inStr = true
        elseif c == '{'
            depth += 1
        elseif c == '}'
            depth -= 1
            depth == 0 && return :malformed   # closed: the JSON itself is wrong
        end
    end
    return :truncated                        # opened, never closed
end

"""
    recoverTruncatedSend(reply) :: Union{Nothing,String}

When the provider cuts a `send` object after a complete command (the ShadowTerm run:
`{"action":"send","code":"find ... | head -200` with no closing quote/brace),
the command itself is still usable. Recover it ONLY when the shell text is
obviously complete: balanced quotes, no trailing operator/backslash, and no
heredoc. This converts an output-cap truncation into one executed turn instead
of three identical unparseable strikes and a dead run.
"""
function recoverTruncatedSend(reply::AbstractString)::Union{Nothing,String}
    text = strip(stripProviderMarkup(stripThinking(reply)))
    m = match(r"\{\s*\"action\"\s*:\s*\"send\"\s*,\s*\"code\"\s*:\s*\"", text)
    m === nothing && return nothing
    start = m.offset + ncodeunits(m.match)
    start > ncodeunits(text) && return nothing
    # m.offset is a byte offset. Convert to a character index safely.
    startChar = thisind(text, start)
    raw = text[startChar:end]
    val = IOBuffer()
    closed = false
    j = firstindex(raw)
    while j <= lastindex(raw)
        c = raw[j]
        if c == '\\'
            j == lastindex(raw) && return nothing   # dangling escape
            nxt = raw[nextind(raw, j)]
            print(val, c, nxt)
            j = nextind(raw, nextind(raw, j))
        elseif c == '"'
            closed = true
            break
        else
            print(val, c)
            j = nextind(raw, j)
        end
    end
    rawVal = String(take!(val))
    isempty(strip(rawVal)) && return nothing
    # Decode JSON escapes through the same repair path used for balanced objects.
    probe = _tryParseActionCandidate("{\"action\":\"send\",\"code\":\"" * rawVal * "\"}")
    probe === nothing && return nothing
    code = getstr(probe, "code", "")
    isempty(strip(code)) && return nothing
    occursin('\n', code) && return nothing                  # actions are one line
    occursin("<<", code) && return nothing                   # heredoc may be cut
    occursin(r"(&&|\|\||\|)\s*$", code) && return nothing
    occursin(r"(?<!\\)\\\s*$", code) && return nothing
    # A dangling option/bare command would parse but may wait on stdin
    # (`grep -R`), so it is not a safe recovered send.
    occursin(r"\s-{1,2}[A-Za-z][A-Za-z0-9-]*\s*$", code) && return nothing
    occursin(r"\b(find|grep|rg|sed|head|tail|cat|ls|git|which|echo|printf)\s*$", code) &&
        return nothing
    shellQuotesBalanced(code) || return nothing
    shellParseOK(code) || return nothing
    return String(strip(code))
end

"Shell-aware quote balance: a double quote inside single quotes is literal."
function shellQuotesBalanced(code::AbstractString)::Bool
    state = :none
    esc = false
    for c in code
        if state === :single
            c == '\'' && (state = :none)
        elseif state === :double
            if esc
                esc = false
            elseif c == '\\'
                esc = true
            elseif c == '"'
                state = :none
            end
        else
            if esc
                esc = false
            elseif c == '\\'
                esc = true
            elseif c == '\''
                state = :single
            elseif c == '"'
                state = :double
            end
        end
    end
    return state === :none
end

"True when `code` is syntactically complete zsh (parses with `zsh -n`)."
function shellParseOK(code::AbstractString)::Bool
    try
        return success(run(pipeline(Cmd(["zsh", "-n", "-c", String(code)]);
                                    stdout = devnull, stderr = devnull)))
    catch
        false
    end
end

function recoverBareCommand(reply::AbstractString)::Union{Nothing,String}
    text = strip(stripProviderMarkup(stripThinking(reply)))
    occursin('{', text) && return nothing
    lines = [strip(l) for l in split(text, '\n') if !isempty(strip(l))]
    length(lines) == 1 || return nothing
    line = lines[1]
    startswith(line, "\$") && (line = strip(line[2:end]))
    isempty(line) && return nothing
    occursin(r"[.!?]\s*$", line) && return nothing                 # prose
    (occursin(SHELL_COMMAND_RE, line) || occursin(JULIA_STATEMENT_RE, line)) ||
        return nothing
    return line
end

"""Parse one balanced `{…}` candidate as an action object: strictly first,
then through escalating REPAIR TIERS (control chars → inner-quote escape).
Returns JSON3.Object or nothing."""
# Commands a bare reply may legitimately be (used by recoverBareCommand).
const SHELL_COMMAND_RE = Regex("^(cd|ls|pwd|echo|cat|sed|awk|grep|rg|find|head|tail|" *
    "git|julia|juliaup|mkdir|rmdir|rm|cp|mv|touch|chmod|ln|make|bat|batcat|less|" *
    "micro|vim|nano|python3?|pip3?|curl|wget|ssh|scp|rsync|tar|unzip|zip|diff|wc|" *
    "sort|uniq|export|source|which|env|test|jq|timeout|tree|stat|du|df|ps|kill|" *
    "pkill)\\b")

# A bare Julia/Pkg statement is as recoverable as a shell command (observed:
# `using Pkg; Pkg.status("WGPUCompute")` was burned as "unparseable").
const JULIA_STATEMENT_RE = Regex("^(using|import|include|println|print|display|show|" *
    "function|struct|mutable|module|baremodule|begin|let|for|while|if|try|return|" *
    "local|const|global|run|ccall|open|read|write|cd|pwd)\\b|" *
    "^(Pkg|Base|Main|ENV)\\b|^[A-Za-z_][A-Za-z0-9_]*\\s*=")

const _VALID_JSON_ESC = Set(['"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'])

"""
    _fixInvalidJsonEscapes(s) :: String

JSON has no `\\xNN`, `\\e` or other C escapes, but models write them:
`{"keys":"\\x11"}` (a Ctrl-Q) made the parser throw "invalid escape character", and that
exception escaped the parser and KILLED the run with no feedback. Translate inside
string literals: `\\xNN` -> `\\u00NN`, `\\e` -> `\\u001b`; keep the valid escapes;
turn anything else into a literal backslash.
"""
function _fixInvalidJsonEscapes(s::String)
    occursin('\\', s) || return s
    chars = collect(s)
    n = length(chars)
    out = IOBuffer(sizehint = sizeof(s) + 16)
    inStr = false
    i = 1
    while i <= n
        c = chars[i]
        if !inStr
            c == '"' && (inStr = true)
            print(out, c)
            i += 1
            continue
        end
        if c == '"'
            inStr = false
            print(out, c)
            i += 1
            continue
        end
        if c != '\\'
            print(out, c)
            i += 1
            continue
        end
        nxt = i + 1 <= n ? chars[i + 1] : '\\'
        if nxt == 'u'
            print(out, "\\u")
            i += 2
        elseif nxt == 'x' && i + 3 <= n && all(isxdigit, chars[i + 2:i + 3])
            print(out, "\\u00", chars[i + 2], chars[i + 3])
            i += 4
        elseif nxt == 'e'
            print(out, "\\u001b")
            i += 2
        elseif nxt in _VALID_JSON_ESC
            print(out, '\\', nxt)
            i += 2
        else
            print(out, "\\\\")          # literal backslash + the char after it
            i += 1
        end
    end
    return String(take!(out))
end

function _validateActionJsonStrings(value::Union{JSON3.Object,JSON3.Array})
    for child in values(value)
        if child isa JSON3.Object || child isa JSON3.Array
            _validateActionJsonStrings(child)
        end
    end
    return nothing
end

function _tryParseActionCandidate(candidate::String)
    repaired = _repairJsonCandidate(candidate)
    fixed = _fixInvalidJsonEscapes(repaired)
    # RAW inner quotes must be escaped BEFORE the control/escape repair sees
    # them: the repair toggles string state on every quote, so a `grep -rn
    # "X\|Y" src/` code value made every later tier mis-parse. Also fix invalid
    # `\|` escapes on that escaped form (models write regex alternation raw).
    escaped = _escapeInnerQuotes(candidate)
    for text in (candidate, repaired, fixed, escaped,
                 _fixInvalidJsonEscapes(escaped), _escapeInnerQuotes(fixed))
        # Parse inside the try so malformed model output reaches the repair tiers.
        parsed = try
            obj = JSON3.read(text)
            # Force JSON3's lazy strings inside the repair boundary, including nested fields.
            _validateActionJsonStrings(obj)
            # `decision` is the AMBIENT MONITOR's protocol ({decision:observe|insight|…});
            # requiring `action` silently dropped every monitor decision.
            (haskey(obj, :action) || haskey(obj, :decision)) ? obj : nothing
        catch
            nothing
        end
        parsed === nothing || return parsed
    end
    return nothing
end

_nextNonWsAt(chars::Vector{Char}, from::Int) = begin
    j = from
    while j <= length(chars) &&
          (chars[j] == ' ' || chars[j] == '\t' || chars[j] == '\n' ||
           chars[j] == '\r')
            j += 1
    end
    return j
end

"""LAST-RESORT repair for the most common weak-model slip (observed live:
granite4 writing `run `import Pkg; Pkg.add("CUDA")` inside a feedback value):
RAW unescaped `"` inside string values. SEQUENTIAL STATE MACHINE: outside a
string every quote OPENS one; inside a string a quote CLOSES it only when
followed by `:` / `}` / `]`, or — for the ambiguous `", ` shape
(`println("hello", 42)`) — when the next quote after the comma introduces a
NEW KEY (`", "b": …`). Everything else is an inner quote and gets escaped."""
function _escapeInnerQuotes(s::AbstractString)
    chars = collect(s)
    n = length(chars)
    out = IOBuffer(sizehint = sizeof(s) + 8)
    inStr = false
    esc = false
    for idx in 1:n
        c = chars[idx]
        if !inStr
            c == '"' && (inStr = true)
            print(out, c)
        elseif esc
            esc = false
            print(out, c)
        elseif c == '\\'
            esc = true
            print(out, c)
        elseif c == '"'
            j = _nextNonWsAt(chars, idx + 1)
            isCloser = j <= n &&
                       (chars[j] == ':' || chars[j] == '}' || chars[j] == ']')
            if !isCloser && j <= n && chars[j] == ','
                # Ambiguous `", ` shape: closer only if the next quoted
                # segment is a KEY — i.e. its OWN closing quote is followed
                # by `:` (so `","kind":"warn"` closes, `", 42)"}` does not).
                q = findnext(==('"'), chars, j + 1)
                if q === nothing
                    isCloser = false       # comma but no later quote → prose
                else
                    q2 = findnext(==('"'), chars, q + 1)
                    k3 = q2 === nothing ? 0 : _nextNonWsAt(chars, q2 + 1)
                    isCloser = k3 > 0 && k3 <= n && chars[k3] == ':'
                end
            end
            if isCloser
                inStr = false
                print(out, c)
            else
                print(out, '\\')
                print(out, c)
            end
        else
            print(out, c)
        end
    end
    return String(take!(out))
end

"""Make near-valid model JSON parseable WITHOUT touching semantics:
(1) escape raw \n/\r/tab/control characters that sit INSIDE string literals
(a literal newline in a value is illegal JSON but common in pretty-printed
model output), then (2) straighten typographic quotes. Structure-aware:
control chars OUTSIDE strings are already legal whitespace and stay put."""
function _repairJsonCandidate(s::String)
    out = IOBuffer(sizehint = sizeof(s) + 8)
    inStr = false
    esc = false
    for c in s
        if !inStr
            c == '"' && (inStr = true)
            print(out, c)
        elseif esc
            esc = false
            print(out, c)
        elseif c == '\\'
            esc = true
            print(out, c)
        elseif c == '"'
            inStr = false
            print(out, c)
        elseif c == '\n'
            print(out, "\\n")
        elseif c == '\r'
            print(out, "\\r")
        elseif c == '\t'
            print(out, "\\t")
        elseif c < ' '
            print(out, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else
            print(out, c)
        end
    end
    t = String(take!(out))
    occursin(r"[“”»«]", t) &&
        (t = replace(t, "“" => "\"", "”" => "\"", "«" => "\"", "»" => "\""))
    return t
end

function _parallelSends(obj)
    raw = get(obj, Symbol("sends"), nothing)
    raw === nothing && return ParallelSend[]
    items = ParallelSend[]
    try
        for it in raw
            push!(items, ParallelSend(lowercase(String(getstr(it, "target", "main"))),
                                      String(getstr(it, "code", ""))))
        end
    catch
        return ParallelSend[]
    end
    return items
end

getstr(obj, key, default = "") = begin
    v = get(obj, Symbol(key), nothing)
    v === nothing ? String(default) : String(v)
end

# ---- action dispatch --------------------------------------------------------
# The model's one JSON action, parsed into a concrete type so the loop
# dispatches instead of chaining `kind == "…"` string tests.
abstract type AbstractAction end
struct SendAction        <: AbstractAction
    code::String
    target::String          # "main" (default) | "child:N" — a child session
end
SendAction(code::AbstractString) = SendAction(String(code), "main")
struct ParallelSend
    target::String
    code::String
end
struct ParallelAction    <: AbstractAction
    sends::Vector{ParallelSend}
end
struct TypeAction        <: AbstractAction; keys::String; end
struct NewTerminalAction <: AbstractAction; reason::String; end
struct NewChatAction    <: AbstractAction; reason::String; end
struct SplitTerminalAction <: AbstractAction
    reason::String
    orientation::String
end
struct CloseSplitAction    <: AbstractAction; end
struct CompactAction       <: AbstractAction; end
struct WaitAction        <: AbstractAction; seconds::Float64; end
struct InterruptAction   <: AbstractAction; reason::String; end
struct FeedbackAction    <: AbstractAction; title::String; body::String; kind::String; end
struct DoneAction        <: AbstractAction; summary::String; end
struct UnknownAction     <: AbstractAction; kind::String; end

"Parse the model's action object into a concrete `AbstractAction`."
function parseAction(obj)::AbstractAction
    kind = getstr(obj, "action", "")
    kind == "send" && return SendAction(getstr(obj, "code"),
                                         lowercase(getstr(obj, "target", "main")))
    kind == "parallel" && return ParallelAction(_parallelSends(obj))
    kind == "type" && return TypeAction(getstr(obj, "keys"))
    kind == "newTerminal" && return NewTerminalAction("")
    kind == "newChat" && return NewChatAction(getstr(obj, "reason"))
    kind == "splitTerminal" && return SplitTerminalAction(
        getstr(obj, "reason"), getstr(obj, "orientation", "vertical"))
    kind == "closeSplit" && return CloseSplitAction()
    kind == "compact" && return CompactAction()
    kind == "wait" &&
        return WaitAction(clamp(Float64(get(obj, :seconds, 1.0)), 0.1, 10.0))
    kind == "interrupt" && return InterruptAction(getstr(obj, "reason"))
    kind == "feedback" && return FeedbackAction(getstr(obj, "title", "Flooty Agent"),
                                                getstr(obj, "body"),
                                                getstr(obj, "kind", "info"))
    kind == "done" && return DoneAction(getstr(obj, "summary"))
    return UnknownAction(kind)
end


"""
Mutable state shared by `runAgentLoop!` and the `performAction!` branches. Every
field is a local the loop mutates across turns, lifted so a branch can reach it.
"""
Base.@kwdef mutable struct LoopContext
    sess::ReplSession
    task::String
    conv::Conversation
    completeFn::Union{Nothing,Function}
    onEvent::Function
    evalTimeoutS::Float64
    waitTimeoutS::Float64
    result::AgentLoopResult
    messages::Vector{OllamaMessage}
    emptyTypeStrikes::Int = 0
    lastFeedbackSig::String = ""
    toolSeq::Int = 0
    currentToolId::String = ""
    # The model's context window and this turn's estimated footprint.
    contextLimit::Int = 0
    contextTokens::Int = 0
    compactions::Int = 0
    # STREAMING THINKING: reasoning arrives while the model is still generating;
    # we coalesce it here and push it in small batches so the chat shows the
    # monologue live instead of one block at the end.
    thinkingPending::String = ""
    thinkingFlushedAt::Float64 = 0.0
    streamedThinking::Bool = false
    # Monitor observations arriving while a send/model is in flight. They are
    # injected as notes immediately before the NEXT model call, after the
    # snapshot, so they are the last context the driver reads — without
    # interrupting the current action.
    monitorNotesPending::Vector{String} = String[]
end

"""
    streamThinking!(ctx, chunk) / flushThinking!(ctx)

Feed reasoning from the STREAMING client to the page. Chunks are coalesced
(150 ms or 400 chars) so a fast model does not flood the UI with one event per
token; the transcript still receives the FULL thinking once, at the end of the
turn (`recordAgentEvent!`).
"""
function streamThinking!(ctx::LoopContext, chunk::AbstractString)
    ctx.thinkingPending *= String(chunk)
    ctx.streamedThinking = true
    if (time() - ctx.thinkingFlushedAt) >= 0.15 || length(ctx.thinkingPending) >= 400
        flushThinking!(ctx)
    end
    return nothing
end

function flushThinking!(ctx::LoopContext)
    isempty(ctx.thinkingPending) && return 0
    text = ctx.thinkingPending
    ctx.thinkingPending = ""
    ctx.thinkingFlushedAt = time()
    shown = stripProviderMarkup(text)
    if !isempty(strip(shown))
        pushAgentEventToWindow(activeTerminalUiWebview(),
                               AgentThinkingEvent(sessionIdFor(ctx.sess), String(shown)))
    end
    return length(text)
end

# The loop's stream helpers, lifted to `LoopContext` methods so both the loop and
# the action branches share one definition (the terminal id tags every line).
function loopLog(ctx::LoopContext, line::AbstractString)
    push!(ctx.result.transcript, String(line))
    @debug string("[agent-turn] ", line)
    return nothing
end

# Which status lines are DIAGNOSTICS (they also land in the chat transcript as
# warn/error bubbles) rather than progress narration. Prefix-driven so every guard
# and failure site is covered without threading a level through all call sites.
function statusLevel(line::AbstractString)::Symbol
    startswith(line, "[error]") && return :error
    (startswith(line, "[warn]") || startswith(line, "[loop-guard]") ||
     startswith(line, "[stop]")) && return :warn
    return :info
end

function loopSay(ctx::LoopContext, line::AbstractString)
    loopLog(ctx, line)
    try
        trajectoryStatus!(ctx.sess, line)
    catch
    end
    pushAgentEventToWindow(activeTerminalUiWebview(),
                           AgentStatusEvent(sessionIdFor(ctx.sess), String(line),
                                            statusLevel(line)))
    return nothing
end

# ---- driver parse-failure heartbeat ----------------------------------------
# The monitor watches the PTY; malformed model replies never touch it. Publish
# consecutive parse failures so the monitor can notice the driver is stuck
# before any output exists. Advice only.
const AGENT_PARSE_FAILURES = IdDict{Any,Int}()
const AGENT_PARSE_LAST = IdDict{Any,String}()
const AGENT_PARSE_LOCK = ReentrantLock()

function noteAgentParseFailure!(sess, text::AbstractString)
    lock(AGENT_PARSE_LOCK) do
        AGENT_PARSE_FAILURES[sess] = get(AGENT_PARSE_FAILURES, sess, 0) + 1
        AGENT_PARSE_LAST[sess] = String(text)
    end
    return nothing
end

function clearAgentParseFailure!(sess)
    lock(AGENT_PARSE_LOCK) do
        delete!(AGENT_PARSE_FAILURES, sess)
        delete!(AGENT_PARSE_LAST, sess)
    end
    return nothing
end

agentParseFailureFor(sess) = lock(AGENT_PARSE_LOCK) do
    (get(AGENT_PARSE_FAILURES, sess, 0), get(AGENT_PARSE_LAST, sess, ""))
end

# ---- driver model-wait heartbeat -------------------------------------------
# The terminal monitor watches the PTY, so a driver blocked in an LLM call looks
# like an idle prompt. Publish the wait start/end so the monitor can say so.
const AGENT_MODEL_WAIT = IdDict{Any,Float64}()
const AGENT_MODEL_WAIT_LOCK = ReentrantLock()

function setAgentModelWait!(sess, active::Bool)
    lock(AGENT_MODEL_WAIT_LOCK) do
        active ? (AGENT_MODEL_WAIT[sess] = time()) :
                 delete!(AGENT_MODEL_WAIT, sess)
    end
    return nothing
end

"Start time of `sess`'s in-flight driver model call, or 0.0."
agentModelWaitFor(sess) = lock(AGENT_MODEL_WAIT_LOCK) do
    get(AGENT_MODEL_WAIT, sess, 0.0)
end

"""
    withModelProgress(ctx, phase, f)

Run a model call while the UI shows WHAT the agent is doing and for HOW LONG.
`phase` seeds the line ("waiting for the model"); a background task refreshes it
every few seconds with the elapsed time and clears it when `f` returns. Without
this a slow completion (30-120 s of silence after the reasoning stops) is
indistinguishable from a dead window.
"""
const MODEL_PROGRESS_EVERY_S = 5.0

# `f` FIRST: callers use `do`, which passes the closure as the first argument.
function withModelProgress(f, ctx::LoopContext, phase::AbstractString)
    wv = activeTerminalUiWebview()
    sid = sessionIdFor(ctx.sess)
    stop = Ref(false)
    t0 = time()
    sayProgress(n) = wv === nothing ? nothing :
        pushAgentEventToWindow(wv, AgentProgressEvent(sid, string(phase, "… ",
                                                               n, "s")))
    sayProgress(0)
    setAgentModelWait!(ctx.sess, true)
    task = @async begin
        while !stop[]
            sleep(MODEL_PROGRESS_EVERY_S)
            stop[] && break
            sayProgress(round(Int, time() - t0))
        end
    end
    try
        return f()
    finally
        setAgentModelWait!(ctx.sess, false)
        stop[] = true
        wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sid, ""))
    end
end

function loopTool(ctx::LoopContext, name::AbstractString, detail::AbstractString)
    loopLog(ctx, "[turn $(ctx.result.turns)] $name: $detail")
    # Publish what the agent is doing so the monitor's prompt is about THIS task
    # (the agent -> monitor half of the channel).
    setAgentBrief!(ctx.sess, "task: " * first(ctx.task, 240) *
                             "\nlast action: " * name * " " * first(detail, 240))
    ctx.toolSeq += 1
    ctx.currentToolId = "t$(ctx.result.turns)-$(ctx.toolSeq)"
    ev = AgentToolCallEvent(sessionIdFor(ctx.sess), ctx.currentToolId, String(name),
                            String(detail))
    try
        trajectoryToolCall!(ctx.sess, name, detail)
    catch
    end
    recordAgentEvent!(ctx.conv, ev)
    pushAgentEventToWindow(activeTerminalUiWebview(), ev)
    return nothing
end

function loopToolResult(ctx::LoopContext, ok::Bool, detail::AbstractString)
    loopLog(ctx, "    -> $(ok ? "ok" : "ERR"): $detail")
    ev = AgentToolResultEvent(sessionIdFor(ctx.sess), ctx.currentToolId, ok, String(detail))
    try
        trajectoryToolResult!(ctx.sess, ok, detail)
    catch
    end
    recordAgentEvent!(ctx.conv, ev)
    pushAgentEventToWindow(activeTerminalUiWebview(), ev)
    return nothing
end

"""
    resolveChildTarget(main, target) -> ReplSession | nothing

One child-terminal space: `"child:1"`, `"child:2"` index the parent's terminal
children (creation order). `"split"` is an alias for the NEWEST child session
(the view shows one session at a time, so there is no split presentation any
more); `"split:N"` aliases `"child:N"`.
"""
function resolveChildTarget(main, target::AbstractString)
    t = lowercase(strip(String(target)))
    t == "main" && return main isa ReplSession ? main : nothing
    if t == "split"
        # The newest child session.
        kids = childTerminals(main)
        return isempty(kids) ? nothing : kids[end].repl
    end
    m = match(r"^(?:child|split):(\d+)$", t)
    m === nothing && return nothing
    node = childTerminalAt(main, parse(Int, m.captures[1]))
    return node === nothing ? nothing : node.repl
end
resolveSplitTarget(main, target::AbstractString) = resolveChildTarget(main, target)

"""
Poll the monitor channel while a `send` is blocked in the PTY. Notes arrive in
the next model turn; an interrupt request aborts THIS send.
"""
function monitorSendPoll!(ctx::LoopContext)::Symbol
    reason = takeMonitorInterrupt!(ctx.sess)
    if !isempty(reason)
        loopSay(ctx, "[monitor] interrupt requested: " * first(reason, 160))
        push!(ctx.messages,
              OllamaMessage(role = "user",
                  content = "MONITOR INTERRUPT: " * reason *
                            "\n(The monitor asked to stop the running statement; " *
                            "it was interrupted.)"))
        return :interrupt
    end
    for note in takeMonitorNotes!(ctx.sess)
        loopSay(ctx, "[monitor] " * first(note, 160))
        # IN-FLIGHT NOTIFICATION: the model request is blocked in the send, so
        # this cannot enter that completion. Surface it now in the driver's live
        # phase line; the note itself is queued for the next completion.
        wv = activeTerminalUiWebview()
        wv === nothing || pushAgentEventToWindow(wv,
            AgentProgressEvent(sessionIdFor(ctx.sess),
                "monitor: " * first(note, 120)))
        push!(ctx.monitorNotesPending, String(note))
    end
    return :continue
end

"""
    performAction!(ctx, action, snap) :: Symbol

Run one parsed action; `:continue` for the next turn, `:break` to stop the run.
"""
function performAction!(ctx::LoopContext, action::SendAction,
                        snap::TerminalSnapshot)::Symbol
    # TANDEM: `target` "split" sends to the SECOND terminal (the child pane), whose
    # session is independent of the main one — a Julia REPL can keep running in the
    # main pane while shell work happens in the child.
    target = lowercase(String(action.target))
    sess = ctx.sess
    splitTarget = startswith(target, "split") || startswith(target, "child")
    # EVERY refused send must be a TOOL RESULT, not just a note: a guard that
    # returns before `loopTool` left the Agent transcript with no `send` block
    # and no outcome, so the driver looked like it had lost feedback.
    codeText = String(action.code)
    function sendRefused(reason::AbstractString, note::AbstractString)
        loopTool(ctx, "send" * (target == "main" ? "" : " (" * target * ")"),
                 first(codeText, 120))
        loopToolResult(ctx, false, first(reason, 300))
        loopSay(ctx, "[loop-guard] send refused: " * reason)
        push!(ctx.messages, OllamaMessage(role = "user",
            content = "ACTION RESULT: ERROR — " * reason * "\n" * note))
        return :continue
    end
    if target != "main" && !splitTarget
        return sendRefused("unknown target " * repr(target),
            "SYSTEM NOTE: unknown target " * repr(target) *
            "; use \"main\", \"child:N\" or \"split\" (the newest child).")
    end
    split = splitTarget ? resolveChildTarget(ctx.sess, target) : nothing
    if splitTarget
        if split === nothing
            return sendRefused("no child terminal " * repr(target),
                "SYSTEM NOTE: there is no split pane " * repr(target) *
                " right now. Use splitTerminal/newTerminal first, " *
                "or send to the main terminal (omit \"target\").")
        end
        sess = split
    end
    atTargetPrompt = sess === ctx.sess ? snap.atPrompt :
                     (isempty(FlootyPTYLayer.pendingInputLine(sess)) &&
                      atIdlePrompt(sess))
    pending = try
        sess === ctx.sess ? snap.inputLine : FlootyPTYLayer.pendingInputLine(sess)
    catch
        ""
    end
    # STALE SNAPSHOT: `snap.atPrompt` was captured BEFORE the model call. A
    # heredoc/pager can close while the model is thinking, so the guard must
    # re-check the LIVE prompt before refusing a perfectly valid send.
    if !atTargetPrompt && sess === ctx.sess && isempty(strip(pending)) &&
       atIdlePrompt(sess)
        atTargetPrompt = true
    end
    # STRAY KEYS: keys typed for a pager that had already exited (or a failed
    # `type`) sit on the prompt line and every send is refused forever (observed:
    # a full run died waiting). When WE own the pane and no app owns the screen,
    # clear the line deterministically (Ctrl-U) and send anyway.
    if !atTargetPrompt && sess === ctx.sess && !isempty(pending) &&
       !snap.fullscreen && !snap.appRunning &&
       currentState(sess.control) == :agent
        loopSay(ctx, "[loop-guard] cleared leftover input " * repr(pending) *
                     " before sending")
        FlootyPTYLayer.userWrite(sess, "\x15")
        sleep(0.15)
        pending = FlootyPTYLayer.pendingInputLine(sess)
        atTargetPrompt = isempty(pending)
    end
    ps2 = try
        FlootyPTYLayer.shellAtPS2(sess)
    catch
        false
    end
    recoveredContinuation = false
    # HEREDOC-LIKE WEDGE: an earlier send left the shell at PS2. Do not spend
    # turns telling a long-running harness to type Ctrl+C by hand; when the
    # agent owns input, abort the incomplete continuation and send normally.
    if !atTargetPrompt && ps2 && isempty(strip(pending))
        recoveredContinuation = try
            FlootyPTYLayer.recoverStuckContinuation!(sess)
        catch
            false
        end
        if recoveredContinuation
            atTargetPrompt = true
            pending = ""
            loopSay(ctx, "[loop-guard] recovered a stuck heredoc/PS2 continuation")
        end
    end
    if !atTargetPrompt
        reason = ps2 ?
            "the shell is at a PS2 continuation (heredoc/quote); the send was not typed" :
            "not at an idle prompt; the send was not typed"
        note = if ps2
            "SYSTEM NOTE: the shell is inside a heredoc/quote continuation " *
            "(prompt " * repr(FlootyPTYLayer.promptSegment(sess)) * "). Do NOT send " *
            "more commands. Finish it with the delimiter line via " *
            "{\"action\":\"type\",\"keys\":\"EOF\\r\"} (or the heredoc's actual " *
            "delimiter), or abort with {\"action\":\"type\",\"keys\":\"\\x03\"} " *
            "(Ctrl+C); then retry the send."
        elseif isempty(pending)
            "SYSTEM NOTE: the terminal is NOT at an idle prompt right now — " *
            "do NOT send code; use {\"action\":\"wait\",\"seconds\":5} or refine " *
            "once the shell/application banner shows a prompt."
        else
            "SYSTEM NOTE: the prompt line already contains typed text " *
            repr(pending) * " (a stray key press). Sending would append to it. " *
            "Clear it with {\"action\":\"type\",\"keys\":\"\\x15\"} (Ctrl-U) or " *
            "{\"action\":\"type\",\"keys\":\"\\x03\"} (Ctrl-C), or submit it " *
            "with {\"action\":\"type\",\"keys\":\"\\r\"} — then continue."
        end
        return sendRefused(reason * (isempty(pending) ? "" :
                                     "; input line holds " * repr(pending)), note)
    end
    code = action.code
    if length(code) > SEND_MAX_CODE_CHARS
        # A multi-thousand-char pipeline in one JSON string is what the provider
        # truncates mid-string (then the reply is unparseable three times and the
        # run dies). Refuse it HERE, where the model can still be steered.
        return sendRefused(
            "code is $(length(code)) chars (max $(SEND_MAX_CODE_CHARS)); split it",
            "SYSTEM NOTE: that command was too long to " *
            "send in one action ($(length(code)) chars, " *
            "limit $(SEND_MAX_CODE_CHARS)). Split it into " *
            "several smaller \"send\" actions, each " *
            "doing one step, and keep output short " *
            "(head/tail/sed ranges).")
    end
    loopTool(ctx, splitTarget ? "send (" * target * ")" : "send", first(code, 120))
    # Interactive foreground programs (ssh, vim, a nested shell) never return, so
    # `agentWriteAndWait` types them plain and resolves as soon as they START
    # (`errorKind = :running`). One call site for both kinds — the classification
    # lives in the UI layer, where the PTY stream is understood.
    interactive = FlootyPTYLayer.isInteractiveCommand(code)
    ok, excerpt = agentSendStatement!(sess, code; timeoutS = ctx.evalTimeoutS,
                                      poll = () -> monitorSendPoll!(ctx))
    if recoveredContinuation
        excerpt = "[recovered from a stuck heredoc/PS2 continuation]\n" * excerpt
    end
    verdict = ok ? (interactive ? "STARTED (still running)" : "ok") : "ERROR"
    note = interactive && ok ?
           "\nThe command is an interactive program and is STILL RUNNING: the " *
           "terminal is now inside it. Send the next input for THAT session " *
           "(a command, `exit`), or use {\"action\":\"wait\"} to watch it." : ""
    push!(ctx.messages, OllamaMessage(role = "user", content = "ACTION RESULT: " * verdict *
            note * "\n" *
            first(FlootyPTYLayer.scrubSentinelLines(
                ansiStrip(excerpt)), 2000)))
    # Status stream must be DISPLAY-SAFE: scrub eval-bookkeeping sentinels/PUA
    # glyphs (same contract as snapshots) and flatten newlines — the status strip
    # renders ONE line, and raw multiline excerpts garble it against the pane below.
    excerptFlat = replace(
        FlootyPTYLayer.scrubSentinelLines(ansiStrip(excerpt)),
        r"[\r\n]+" => " | ")
    loopToolResult(ctx, ok, first(excerptFlat, 300))
    # Explicit outcome feedback: the next decision must not depend on the model
    # noticing the error inside a raw tail.
    verdict = ok ? "ok" : "ERROR"
    push!(ctx.messages,
          OllamaMessage(role = "user", content = "ACTION RESULT: " * verdict * "\n" *
                  first(FlootyPTYLayer.scrubSentinelLines(
                      ansiStrip(excerpt)), 500)))
    return :continue
end

"""
    decodeTypeKeys(keys) :: String

Decode the C-style escapes a model writes in a `type` action's keys: `\r`
(Enter), `\n`, `\t`, `\e`/`\x1b` (Esc), `\x03` (Ctrl-C), `\x11` (Ctrl-Q),
`\\` (a literal backslash). Observed live: the model emitted `"keys":"\\r"`
intending Enter; writing that verbatim typed a backslash and an `r` at the shell
prompt, so the command never ran and the turn looped. Unknown escapes stay
literal.
"""
function decodeTypeKeys(keys::AbstractString)::String
    s = String(keys)
    occursin('\\', s) || return s
    try
        return Base.unescape_string(s)
    catch
        return s
    end
end

function performAction!(ctx::LoopContext, action::TypeAction,
                        snap::TerminalSnapshot)::Symbol
    keys = decodeTypeKeys(action.keys)
    if isempty(keys)
        # An empty `type` is the agent's equivalent of "wait" with no information:
        # silent forever it burns turn after turn (observed: 34 turns).
        ctx.emptyTypeStrikes += 1
        loopSay(ctx, "[loop-guard] type: empty keystrokes refused " *
                     "($(ctx.emptyTypeStrikes)/3)")
        push!(ctx.messages,
              OllamaMessage(role = "user",
                            content = "SYSTEM NOTE: `type` needs keys. Control keys " *
                                      "are written as escapes: Enter = \\r, " *
                                      "Ctrl-C = \\x03, Esc = \\x1b, Tab = \\t."))
        return :continue
    end
    ctx.emptyTypeStrikes = 0
    # A LARGE multi-line type payload is a file/heredoc write, not a UI key
    # sequence. Writing it while a command is still running/a pager owns the
    # pane sends the body into the wrong program (observed: interleaved chars
    # and a corrupted Julia file). Require the live shell prompt before typing.
    if occursin("<<", keys) || (ncodeunits(keys) > 200 && occursin('\n', keys))
        at_shell = try
            atIdlePrompt(ctx.sess, FlootyPTYLayer.promptSegment(ctx.sess)) &&
            isempty(FlootyPTYLayer.pendingInputLine(ctx.sess))
        catch
            false
        end
        if !at_shell || snap.fullscreen || snap.appRunning
            loopTool(ctx, "type", first(escape_string(keys), 120))
            reason = "large multiline type refused: the terminal is not at a live " *
                     "shell prompt (pager/command/TUI owns the pane)"
            loopToolResult(ctx, false, reason)
            push!(ctx.messages, OllamaMessage(role = "user",
                content = "ACTION RESULT: ERROR — " * reason *
                          "\nWait for the prompt, type q for a pager, then retry; " *
                          "or use small printf/append commands."))
            return :continue
        end
    end
    # A full-screen app that JUST started has not switched the terminal to raw mode
    # yet, and the raw-mode switch flushes pending input: keys written in that
    # window are discarded (observed: the story never appeared in micro). Give the
    # app a beat to start reading, then write.
    (snap.fullscreen || snap.appRunning) && sleep(TYPE_SETTLE_S)
    FlootyPTYLayer.userWrite(ctx.sess, keys)
    loopTool(ctx, "type", first(escape_string(keys), 120))
    sleep(0.25)
    # QUIT CONFIRMATION: "q" in a pager is a request, not a guarantee — a pager
    # sitting on its ":" command prompt needs its own acknowledgment, and a key
    # typed before the app was reading lands at the shell instead. Reporting a
    # bare "typed 1 key" made the model believe the pane was free; the next
    # `send` was then refused forever with "not at an idle prompt" (live after
    # bat/less). Wait briefly and report whether the PROMPT actually returned.
    if snap.fullscreen || snap.appRunning
        quitRequest = keys in ("q", "Q", "\x11", "\x03", "\x04", ":q\r", ":q\n")
        if quitRequest
            deadline = time() + TYPE_QUIT_TIMEOUT_S
            restored = false
            while time() < deadline
                p = try
                    atIdlePrompt(ctx.sess, FlootyPTYLayer.promptSegment(ctx.sess)) &&
                    isempty(FlootyPTYLayer.pendingInputLine(ctx.sess))
                catch
                    false
                end
                if p
                    restored = true
                    break
                end
                sleep(0.05)
            end
            loopToolResult(ctx, true,
                restored ?
                    "typed $(length(keys)) key(s); prompt restored" :
                    "typed $(length(keys)) key(s); the app still owns the pane — " *
                    "send its quit key again (pager: q; micro: Ctrl-Q; editor: its own binding)")
            return :continue
        end
    end
    # EVERY action must close its tool block: an unpaired `toolcall` left the chat
    # and status strip showing "running" forever (reported: "type is in running
    # state but the agent is done with writing").
    loopToolResult(ctx, true, "typed $(length(keys)) key(s)")
    return :continue
end

function performAction!(ctx::LoopContext, action::NewChatAction,
                        ::TerminalSnapshot)::Symbol
    child = try
        launchChildChat!(sessionIdFor(ctx.sess);
                         name = isempty(strip(action.reason)) ? "Chat" :
                                first(strip(action.reason), 40))
    catch err
        loopTool(ctx, "newChat", "failed")
        loopToolResult(ctx, false, sprint(showerror, err))
        return :continue
    end
    loopTool(ctx, "newChat", first(child.id, 8))
    loopToolResult(ctx, true, "child chat opened in its own tab")
    return :continue
end

function performAction!(ctx::LoopContext, ::NewTerminalAction,
                        ::TerminalSnapshot)::Symbol
    opened = FlootyPTYLayer.createTerminalUi(FlootyPTYLayer.activeTerminalUiWebview();
                                             parent_id = sessionIdFor(ctx.sess))
    loopTool(ctx, "newTerminal", opened ? "opened" : "no UI / failed")
    sleep(0.5)
    loopToolResult(ctx, opened, opened ? "opened" : "no UI / failed")
    return :continue
end

"""
    performAction!(ctx, ::SplitTerminalAction, snap)

Open a CHILD SESSION of the current one: the view shows ONE session at a time, so
the child is a node of the tree (its own tab), which the user can switch to.
`closeSplit` closes it again.
"""
function performAction!(ctx::LoopContext, action::SplitTerminalAction,
                        ::TerminalSnapshot)::Symbol
    ok = FlootyPTYLayer.splitTerminalUi(FlootyPTYLayer.activeTerminalUiWebview();
                                        orientation = action.orientation)
    loopTool(ctx, "splitTerminal", ok ? "child session opened" :
                                       "no UI / failed")
    sleep(0.8)     # let the child's session bind before the next snapshot
    loopToolResult(ctx, ok, ok ? "child terminal open" : "no UI / failed")
    return :continue
end

function performAction!(ctx::LoopContext, ::CloseSplitAction,
                        ::TerminalSnapshot)::Symbol
    ok = FlootyPTYLayer.closeChildTerminalUi(FlootyPTYLayer.activeTerminalUiWebview())
    loopTool(ctx, "closeSplit", ok ? "child terminal closed" : "no UI / failed")
    sleep(0.3)
    loopToolResult(ctx, ok, ok ? "child closed" : "no UI / failed")
    return :continue
end

function performAction!(ctx::LoopContext, ::CompactAction,
                        ::TerminalSnapshot)::Symbol
    before = length(ctx.messages)
    # Keep 24 in a long conversation, but an explicit compact in a short run
    # should still fold something instead of being a no-op.
    keep = min(CONTEXT_KEEP_LAST, max(8, before - 4))
    removed, kept = compactMessages!(ctx.messages; keepLast = keep)
    removed > 0 && (ctx.compactions += 1)
    detail = removed > 0 ?
             string(removed) * " messages folded into a digest (" *
             string(before) * " -> " * string(kept) * ")" :
             string(before) * " messages — nothing to fold"
    loopTool(ctx, "compact", detail)
    loopToolResult(ctx, true, detail)
    return :continue
end

function performAction!(ctx::LoopContext, action::WaitAction,
                        ::TerminalSnapshot)::Symbol
    loopTool(ctx, "wait", string(round(action.seconds; digits = 1), "s"))
    sleep(action.seconds)
    loopToolResult(ctx, true, "waited " * string(round(action.seconds; digits = 1)) * "s")
    return :continue
end

function performAction!(ctx::LoopContext, action::InterruptAction,
                        ::TerminalSnapshot)::Symbol
    _, detail = agentInterject!(ctx.sess, action.reason)
    loopTool(ctx, "interrupt", detail)
    loopToolResult(ctx, true, detail)
    ctx.onEvent(AgentFeedback(title = "Flooty Agent",
                              body = "Interrupted own run: " * action.reason,
                              kind = "interrupt",
                              sessionId = sessionIdFor(ctx.sess)))
    return :continue
end

function performAction!(ctx::LoopContext, action::FeedbackAction,
                        ::TerminalSnapshot)::Symbol
    fb = AgentFeedback(title = action.title, body = action.body, kind = action.kind,
                       sessionId = sessionIdFor(ctx.sess))
    loopTool(ctx, "feedback", fb.title * ": " * fb.body)
    loopToolResult(ctx, true, "shown to the user")
    recordAgentEvent!(ctx.conv, AgentTextEvent(sessionIdFor(ctx.sess), fb.body))
    # Popup dedupe: identical title+body surfaced once per run — the status line
    # above still logs every occurrence.
    fbSig = fb.title * "|" * fb.body
    if fbSig != ctx.lastFeedbackSig
        ctx.lastFeedbackSig = fbSig
        ctx.onEvent(fb)
    end
    return :continue
end

const PARALLEL_MAX = 4

function parallelRefuse!(ctx, why::AbstractString)::Symbol
    loopSay(ctx, "[loop-guard] parallel refused: " * why)
    push!(ctx.messages,
          OllamaMessage(role = "user",
              content = "SYSTEM NOTE: parallel batch refused: " * why *
                        "\nUse one action per turn for same-pane or interactive work."))
    return :continue
end

"""
    performAction!(ctx, ::ParallelAction, snap)

Run 2-4 INDEPENDENT sends in different panes at the same time. Preflight is
sequential (targets, idle panes, non-interactive, gates); execution is one
`@async` per pane; the ACTION RESULT lists every item in input order. A pane
has ONE input stream, so the same target twice is refused.
"""
function performAction!(ctx::LoopContext, action::ParallelAction,
                        snap::TerminalSnapshot)::Symbol
    items = action.sends
    (PARALLEL_MAX >= length(items) >= 2) ||
        return parallelRefuse!(ctx, "a batch needs 2..$(PARALLEL_MAX) sends " *
                                     "(got $(length(items)))")
    resolved = Tuple{String,ReplSession,String}[]
    seen = Set{String}()                 # session ids, not target strings
    for item in items
        target = isempty(item.target) ? "main" : String(item.target)
        (target == "main" || startswith(target, "split") ||
         startswith(target, "child")) ||
            return parallelRefuse!(ctx, "unknown target $(repr(target)); use " *
                                         "main, child:N or split")
        sess = target == "main" ? ctx.sess : resolveChildTarget(ctx.sess, target)
        sess === nothing &&
            return parallelRefuse!(ctx, "no child terminal $(repr(target)); spawn one first")
        sid = sessionIdFor(sess)
        sid in seen &&
            return parallelRefuse!(ctx, "two sends to the SAME pane (" * target *
                                         "); a pane has one input stream")
        push!(seen, sid)
        code = String(item.code)
        isempty(strip(code)) &&
            return parallelRefuse!(ctx, "empty code for " * target)
        length(code) <= SEND_MAX_CODE_CHARS ||
            return parallelRefuse!(ctx, "send to " * target * " is $(length(code)) chars " *
                                         "(max $(SEND_MAX_CODE_CHARS))")
        FlootyPTYLayer.isInteractiveCommand(code) &&
            return parallelRefuse!(ctx, "interactive command in a batch (" * target *
                                         "): " * first(code, 60))
        okpane = if target == "main"
            snap.atPrompt && isempty(snap.inputLine)
        else
            pending = try
                FlootyPTYLayer.pendingInputLine(sess)
            catch
                ""
            end
            isempty(pending) &&
                atIdlePrompt(sess) &&
                currentState(sess.control) != :user
        end
        okpane ||
            return parallelRefuse!(ctx, "pane `" * target * "` is not at an idle prompt")
        push!(resolved, (target, sess, code))
    end
    loopTool(ctx, "parallel",
             join([string(t, " ", first(replace(c, r"\s+" => " "), 40))
                   for (t, _, c) in resolved], " | "))
    t0 = time()
    tasks = map(resolved) do (target, sess, code)
        @async begin
            try
                agentSendStatement!(sess, code; timeoutS = ctx.evalTimeoutS)
            catch err
                (false, "batch send failed: " * sprint(showerror, err))
            end
        end
    end
    results = fetch.(tasks)
    allok = all(r -> r[1], results)
    io = IOBuffer()
    print(io, "ACTION RESULT: parallel ", count(r -> r[1], results), "/",
          length(results), " ok in ", round(time() - t0; digits = 2), "s\n")
    for (i, ((target, _, code), (ok, excerpt))) in enumerate(zip(resolved, results))
        print(io, "[", i, "] ", target, " `",
              first(replace(code, r"\s+" => " "), 80), "` -> ",
              ok ? "ok" : "ERROR", "\n",
              first(FlootyPTYLayer.scrubSentinelLines(ansiStrip(excerpt)), 1200),
              "\n")
    end
    text = String(take!(io))
    push!(ctx.messages, OllamaMessage(role = "user", content = text))
    loopToolResult(ctx, allok, first(replace(text, r"\s+" => " "), 300))
    return :continue
end

function performAction!(ctx::LoopContext, action::DoneAction,
                        ::TerminalSnapshot)::Symbol
    ctx.result.summary = action.summary
    ctx.result.ok = true
    loopSay(ctx, "[turn $(ctx.result.turns)] done: " * ctx.result.summary)
    # The agent's ANSWER is text (what it says), not activity: it belongs in the
    # chat, not only in the status strip.
    pushAgentEventToWindow(
        activeTerminalUiWebview(),
        AgentTextEvent(sessionIdFor(ctx.sess),
                       String(stripProviderMarkup(ctx.result.summary))))
    recordAgentEvent!(ctx.conv, AgentTextEvent(sessionIdFor(ctx.sess), ctx.result.summary))
    return :break
end

function performAction!(ctx::LoopContext, action::UnknownAction,
                        ::TerminalSnapshot)::Symbol
    loopSay(ctx, "[turn $(ctx.result.turns)] unknown action '$(action.kind)' — waiting")
    sleep(0.5)
    return :continue
end

"""
    runAgentLoop!(sess, task::AbstractString; completeFn, maxTurns = 12,
                  onEvent = _noopEvent, evalTimeoutS = 60.0,
                  waitTimeoutS = 300.0) :: AgentLoopResult

Drive `sess` toward `task`. `completeFn(messages)::String` returns the next
assistant content (default: Poolside AI poolside/laguna-s-2.1 via OpenAI API). Every turn appends human-readable
lines to `result.transcript`; `onEvent(::AgentFeedback)` fires for feedback/
interrupt actions so callers can bridge them into the UI popup stack.

Warp-style arbitration: when the user takes over mid-run, the loop pauses
(user priority) and waits up to `waitTimeoutS` for a new instruction —
submitting one resumes it with that intent; the timeout yields gracefully
(summary "yielded to user").
"""
# The exact message list of the last run per conversation. `conversationContext`
# is a bounded fallback for cold starts; a warm follow-up should not jump back to
# a seed-sized context the moment the previous run stops.
const LAST_RUN_CONTEXT = IdDict{Any,Vector{OllamaMessage}}()
const LAST_RUN_CONTEXT_LOCK = ReentrantLock()

function clearCachedRunContext!(conv)
    lock(LAST_RUN_CONTEXT_LOCK) do
        delete!(LAST_RUN_CONTEXT, conv)
    end
    return nothing
end

"Previous run's messages (without the old system prompt / stale snapshots)."
function warmRunHistory(conv)::Union{Nothing,Vector{OllamaMessage}}
    cached = lock(LAST_RUN_CONTEXT_LOCK) do
        get(LAST_RUN_CONTEXT, conv, nothing)
    end
    cached === nothing && return nothing
    isempty(conv.messages) && (clearCachedRunContext!(conv); return nothing)
    out = OllamaMessage[]
    for m in cached
        m.role == "system" && continue
        txt = something(m.content, "")
        startswith(txt, "TERMINAL SNAPSHOT") && continue
        push!(out, m)
    end
    return isempty(out) ? nothing : out
end

function storeRunContext!(conv, messages)
    lock(LAST_RUN_CONTEXT_LOCK) do
        LAST_RUN_CONTEXT[conv] = copy(messages)
    end
    return nothing
end

const ACTION_ENCODER_PROMPT = """
You encode a terminal agent's reasoning into exactly ONE action JSON object.
Reply with the object only: no <thinking>, prose, markdown fence, or commentary.
Schema:
{"action":"send","code":"<one shell command>"}
{"action":"type","keys":"<raw keys>"}
{"action":"wait","seconds":2}
{"action":"done","summary":"<result>"}
Use the task and the CURRENT terminal snapshot; do not invent output. If the
reasoning asks to inspect a file, prefer a bounded command. If a pager is open,
use type keys (space/b/q), not send. Escape JSON strings correctly; keep the
command short.
"""

"Turn reasoning-only output into one JSON action via a SHORT encoder prompt."
function encodeActionFromThinking(ctx, thinking::AbstractString)::Union{Nothing,String}
    snap = ""
    for m in reverse(ctx.messages)
        txt = something(m.content, "")
        if startswith(txt, "TERMINAL SNAPSHOT")
            snap = first(txt, 6000)
            break
        end
    end
    ask = OllamaMessage[
        OllamaMessage(role = "system", content = ACTION_ENCODER_PROMPT),
        OllamaMessage(role = "user", content =
            "TASK: " * first(ctx.task, 1200) * "\n\n" *
            "REASONING: " * first(String(thinking), 6000) * "\n\n" *
            (isempty(snap) ? "" : "CURRENT SNAPSHOT:\n" * snap * "\n\n") *
            "Return the single next action JSON now."),
    ]
    out = try
        withModelProgress(ctx, "encoding action") do
            ctx.completeFn(ask)
        end
    catch err
        @debug "action encoder failed" exception = err
        return nothing
    end
    text = strip(stripProviderMarkup(stripThinking(out)))
    isempty(text) && return nothing
    return extractActionJson(text) === nothing ? nothing : String(out)
end

function runAgentLoop!(sess::ReplSession, task::AbstractString;
                       completeFn::Union{Nothing,Function} = actorCompleteFn(),
                       maxTurns::Int = 0,
                       onEvent::Function = _noopEvent,
                       evalTimeoutS::Real = 60.0,
                       waitTimeoutS::Real = 300.0,
                       conversation::Union{Nothing,Conversation} = nothing,
                       contextLimit::Integer = 0)
    # HISTORY: this session's transcript is the app's, not the page's — seed the run
    # with a bounded tail of it so a follow-up instruction can see what the previous
    # run did, then append this run's own messages as it goes.
    conv = conversation === nothing ? conversationFor(sess) : conversation
    # Journal identity: minted once per session (adoption cannot re-key it), so the
    # events of this run are recoverable as one session later.
    journalBindSession!(sess, conv)
    # The window belongs to the MODEL; resolve it BEFORE seeding. A hard 80k
    # character seed looked like a context reset on every new run even on a 1M
    # model. Seed up to ~half the window, leaving the rest for the new run.
    sessionCfg = sessionModelConfig(sess)
    ctxLimit = contextLimit > 0 ? Int(contextLimit) :
               contextLengthFor(sessionCfg.actorModel)
    seedChars = ctxLimit > 0 ? max(80_000, min(2_000_000, Int(ctxLimit) * 2)) :
                               80_000
    warm = warmRunHistory(conv)
    history = warm === nothing ? conversationContext(conv; maxChars = seedChars) : warm
    historySeeded = !isempty(history)
    historyDropped = false
    seededCount = length(history)
    messages = OllamaMessage[OllamaMessage(role = "system", content = AGENT_SYSTEM_PROMPT)]
    append!(messages, history)
    push!(messages, OllamaMessage(role = "user", content = "TASK: $task"))
    recordTask!(conv, task)
    # PER-TAB MODEL: the window, the run and the transcript tag all follow the
    # model THIS session chose (falling back to the process default).
    try
        conv.model = sessionCfg.actorModel
    catch err
        @debug "runAgentLoop!: conversation model tag failed" exception = err
    end
    ctx = LoopContext(sess = sess, task = String(task), conv = conv,
                      completeFn = completeFn, onEvent = onEvent,
                      evalTimeoutS = Float64(evalTimeoutS),
                      waitTimeoutS = Float64(waitTimeoutS),
                      result = AgentLoopResult(), messages = messages,
                      contextLimit = ctxLimit)
    if ctx.completeFn === nothing
        # Built HERE so the thinking sink can reach this run's context.
        ctx.completeFn = actorCompleteFn(sessionCfg;
                                         onThinking = chunk -> streamThinking!(ctx, chunk))
    end
    # VISIBILITY: how much of the conversation this run was seeded with. Without
    # this line "the model forgot the last turn" is guesswork.
    setAgentBrief!(sess, "task: " * first(task, 240))
    publishTerminalStatus!(sess, "running")
    loopSay(ctx, "[seed] " * string(length(history)) * " messages, " *
                 string(sum(m -> length(something(m.content, "")), history; init = 0)) *
                 " chars from the transcript")
    # Anti-parrot state: weak models replay their own failing sends verbatim
    # when context fills with near-identical snapshots. We keep exactly ONE
    # snapshot in context, report every send's outcome EXPLICITLY, and refuse
    # byte-identical re-sends of statements that just errored.
    snapIdx = 0                     # index of the live TERMINAL SNAPSHOT msg
    # Non-send parrot guard: feedback/wait actions CHANGE NOTHING in the
    # terminal, so the next snapshot is byte-identical and weak models answer
    # identically FOREVER (observed: the same feedback popup four turns
    # running). Track the last action's signature; identical repeats get a
    # corrective nudge and are NOT executed; 3 strikes stop the run.
    prevActionSig = ""
    repeatStuck = 0
    lastSendSig = ""
    sendRepeat = 0
    sendDuplicateSkips = 0
    # UNPARSEABLE loop guard: the strike counters above only engage AFTER a
    # reply parses. A model parroting invalid JSON (observed live: granite4
    # emitting raw quotes inside feedback values, 6 turns straight) otherwise
    # burns maxTurns with zero steering. Same 3-strike contract, own counter:
    # reset on every parse success so one bad reply never kills a good run.
    unparseStreak = 0
    reasoningProbeUsed = false
    function finalReport!(ctx, reason)
        prompt = "HARNESS: the tool budget is exhausted (" * reason *
                 "). Do not run tools. Reply with a concise final report: " *
                 "what you learned, the concrete implementation plan, and the " *
                 "first file/edit that should happen next. Plain prose."
        try
            reply = ctx.completeFn(vcat(ctx.messages,
                                        [OllamaMessage(role = "system", content = prompt)]))
            text = strip(stripThinking(reply))
            # Thinking models often answer the final-report prompt with another
            # action object. Do not surface raw JSON as the report; fall back to
            # the transcript's concrete last actions.
            if isempty(text) || startswith(strip(text), "{") ||
               extractActionJson(text) !== nothing
                recent = [strip(l) for l in ctx.result.transcript
                          if startswith(strip(l), "[turn") &&
                             (occursin("send:", l) || occursin("recovered a", l) ||
                              occursin("type:", l))]
                recentSummary = isempty(recent) ? "no successful action" :
                                join([last(r, 180) for r in recent], " | ")
                text = "Stopped: " * reason * ". No edit was made. Last actions: " *
                       recentSummary
            end
            ev = AgentTextEvent(sessionIdFor(ctx.sess), text)
            try recordAgentEvent!(ctx.conv, ev) catch end
            pushAgentEventToWindow(activeTerminalUiWebview(), ev)
            ctx.result.summary = first(text, 800)
            loopSay(ctx, "[final] " * first(replace(text, r"\s+" => " "), 300))
        catch err
            ctx.result.summary = "Stopped: " * reason
            loopSay(ctx, "[final] report failed: " * sprint(showerror, err))
        end
        return nothing
    end
    tagIn(sess.control; mode = :agent)
    try
        trajectoryTask!(sess, task)
        activeTerminalUiWebview() === nothing ||
            startTrajectoryMonitor!(sess)
        while (maxTurns <= 0 || ctx.result.turns < maxTurns)
            # A monitor interrupt is only valid for the send that was running
            # when it was requested; a stale one must not abort a later command.
            clearMonitorInterrupt!(ctx.sess)
            # Warp-style arbitration: the moment the user types or hits Take
            # Over, the control machine flips to :user and this loop PAUSES —
            # it never fights the user for input. It stays alive, waiting for
            # either an assist instruction (submit = resume with new intent)
            # or `waitTimeoutS` seconds of silence (give up gracefully).
            if currentState(ctx.sess.control) == :user
                loopSay(ctx, "[pause] user has the REPL — agent waiting for input")
                ctx.onEvent(AgentFeedback(title = "Flooty Agent",
                                          body = "You took over — agent paused. " *
                                                 "Type in the assist box to hand " *
                                                 "it a new instruction.",
                                          kind = "warn",
                                          sessionId = sessionIdFor(ctx.sess)))
                deadline = time() + ctx.waitTimeoutS
                resumed = false
                held = String[]                     # prompts drained while waiting
                while time() < deadline && !resumed
                    append!(held, takeAssistPrompts!(ctx.sess))
                    if currentState(ctx.sess.control) != :user || !isempty(held)
                        resumed = true
                    end
                    resumed || sleep(0.25)
                end
                append!(held, takeAssistPrompts!(ctx.sess))   # last-moment arrivals
                if resumed
                    for text in held               # deliver EVERYTHING queued
                        loopSay(ctx, "[assist] user says: " * first(text, 120))
                        try
                            noteUserMessage!(ctx.sess, text)
                        catch
                        end
                        push!(ctx.messages,
                              OllamaMessage(role = "user", content = "USER INTERJECTION: " * text *
                                      "\n(Adjust your plan to this instruction.)"))
                    end
                    loopSay(ctx, "[resume] control handed back — continuing task")
                    ctx.onEvent(AgentFeedback(title = "Flooty Agent",
                                              body = "Resumed — working on your " *
                                                     "instruction.",
                                              kind = "info",
                                              sessionId = sessionIdFor(ctx.sess)))
                    currentState(ctx.sess.control) == :agent ||
                        tagIn(ctx.sess.control; mode = :agent)
                    continue
                else
                    push!(ctx.result.transcript,
                          "[yield] no instruction after " *
                          "$(round(ctx.waitTimeoutS; digits = 1))s — agent yielded")
                    ctx.result.summary = "yielded to user"
                    return ctx.result
                end
            end
            # User instructions typed into the assist box arrive here: each one
            # becomes a USER INTERJECTION message so the model re-plans around
            # the user's latest intent.
            intents = takeAssistPrompts!(ctx.sess)
            for text in intents
                loopSay(ctx, "[assist] user says: " * first(text, 120))
                try
                    noteUserMessage!(ctx.sess, text)
                catch
                end
                push!(ctx.messages,
                      OllamaMessage(role = "user", content = "USER INTERJECTION: " * text *
                              "\n(Adjust your plan to this instruction.)"))
            end
            # MONITOR -> AGENT: the ambient monitor's insights are notes, not
            # instructions. They arrive as their own message so the agent can weigh
            # them without adopting the monitor's protocol.
            for note in takeMonitorNotes!(ctx.sess)
                loopSay(ctx, "[monitor] " * first(note, 160))
                push!(ctx.monitorNotesPending, String(note))
            end
            # PARENT -> CHILD steering: the root chat (or any ancestor) can leave
            # notes for this driver; they are instructions, unlike monitor traces.
            for note in takeParentNotes!(sessionIdFor(ctx.sess))
                loopSay(ctx, "[steer] " * first(note, 160))
                push!(ctx.messages,
                      OllamaMessage(role = "user", content = "STEER: " * note *
                              "\n(From the parent session. Adjust the plan.)"))
            end
            # ONE snapshot, always fresh: delete the previous one instead of
            # stacking copies — a long history of near-identical tails makes
            # small models parrot their last answer instead of reading state.
            # CONTEXT BUDGET: measure BEFORE the snapshot goes in, log it next to
            # what the model sees, and compact deterministically when the window
            # is nearly full — no extra model call, so this can never fail.
            # A run turn boundary is the safe place to clear a continuation the
            # PREVIOUS action left behind: nothing is typing right now.
            stuck = try
                FlootyPTYLayer.recoverStuckContinuation!(ctx.sess)
            catch
                false
            end
            stuck && loopSay(ctx,
                "[loop-guard] recovered a stuck heredoc/PS2 continuation at turn start")
            usage = contextUsage(ctx.messages; limit = ctx.contextLimit)
            ctx.contextTokens = usage.tokens
            try
                trajectoryContext!(ctx.sess, usage.tokens, usage.limit)
            catch
            end
            if ctx.contextLimit > 0 && usage.ratio >= CONTEXT_COMPACT_AT
                removed, kept = compactMessages!(ctx.messages)
                if removed > 0
                    ctx.compactions += 1
                    loopSay(ctx, "[compact] context at " *
                                 string(round(Int, usage.ratio * 100)) * "% (" *
                                 formatTokens(usage.tokens) * "/" *
                                 formatTokens(usage.limit) * ") — folded " *
                                 string(removed) * " messages into a digest (" *
                                 string(kept) * " left)")
                else
                    # Too few messages to fold (system + task + a turn): say so
                    # instead of counting a no-op compaction.
                    loopSay(ctx, "[compact] context at " *
                                 string(round(Int, usage.ratio * 100)) *
                                 "% but only " * string(length(ctx.messages)) *
                                 " messages — nothing to fold")
                end
                # Indices moved: re-locate the live snapshot (compaction keeps it)
                snapIdx = findlast(m -> m.role == "user" &&
                                        startswith(something(m.content, ""),
                                                   "TERMINAL SNAPSHOT"),
                                   ctx.messages)
                snapIdx === nothing && (snapIdx = 0)
                # The meter must show the POST-fold budget, not the number that
                # triggered the fold.
                ctx.contextLimit > 0 && begin
                    usage = contextUsage(ctx.messages; limit = ctx.contextLimit)
                    ctx.contextTokens = usage.tokens
                end
            end
            # Status-bar meter: the same estimate the loop logs and compacts by,
            # tagged to THIS tab so switching tabs shows that session's window.
            wvCtx = activeTerminalUiWebview()
            wvCtx === nothing || pushAgentEventToWindow(wvCtx,
                AgentContextUsageEvent(sessionIdFor(ctx.sess),
                                       ctx.contextTokens, ctx.contextLimit))
            # Compaction (automatic below OR the `compact` action) can move or drop
            # the snapshot message, so validate the remembered index before using
            # it — a stale index used to throw BoundsError mid-run.
            if snapIdx > 0
                ok = snapIdx <= length(ctx.messages) &&
                     startswith(something(ctx.messages[snapIdx].content, ""),
                                "TERMINAL SNAPSHOT")
                if !ok
                    found = findlast(m -> m.role == "user" &&
                                           startswith(something(m.content, ""),
                                                      "TERMINAL SNAPSHOT"),
                                     ctx.messages)
                    snapIdx = found === nothing ? 0 : found
                end
            end
            snapIdx > 0 && deleteat!(ctx.messages, snapIdx)
            snap = agentSnapshot(ctx.sess)
            snapshotText = string(snap)
            push!(ctx.messages, OllamaMessage(role = "user", content = "TERMINAL SNAPSHOT\n" * snapshotText))
            snapIdx = length(ctx.messages)
            # MONITOR -> DRIVER: inject pending notes AFTER the snapshot and
            # immediately before the completion, so they are the last context
            # the driver reads. This is context injection only: it never
            # interrupts or skips the current action.
            while !isempty(ctx.monitorNotesPending)
                note = popfirst!(ctx.monitorNotesPending)
                push!(ctx.messages, OllamaMessage(role = "system",
                    content = "MONITOR NOTE (independent observation): " * note *
                              "\nWeigh this note if it is relevant; continue normally."))
            end
            push!(ctx.messages, OllamaMessage(role = "system",
                                              content = AGENT_TURN_REMINDER))
            # VISIBILITY TRACE: log exactly what the model was shown this turn,
            # so "agent isn't seeing the REPL" is checkable from the transcript
            # instead of guesswork (tail head only — enough to spot a stale or
            # empty pane; full text still goes to the LLM).
            ctxLine = ctx.contextLimit > 0 ?
                      "ctx " * formatTokens(ctx.contextTokens) * "/" *
                      formatTokens(ctx.contextLimit) * " (" *
                      string(round(Int, 100 * ctx.contextTokens / ctx.contextLimit)) * "%) " : ""
            loopSay(ctx, "[turn $(ctx.result.turns + 1)] " * ctxLine * "sees: " *
                         first(replace(snapshotText, r"\s+" => " "), 200))
            loopSay(ctx, "[turn $(ctx.result.turns + 1)] thinking…")
            # Some thinking models return reasoning only, with no action JSON.
            # Ask ONCE more in the same turn (the ChatSession driver already
            # does this); otherwise the turn is spent on "[warn] unparseable"
            # and the model spends the next turn re-deriving the same plan.
            reasoningRetried = false
            reply = try
                out = withModelProgress(ctx, "waiting for the model") do
                    ctx.completeFn(ctx.messages)
                end
                flushThinking!(ctx)
                out
            catch err
                # A provider may refuse the SEEDED HISTORY it never produced (Beam
                # rejects a tool message whose call it cannot resolve). That is not a
                # reason to kill the run: drop the history once and try again.
                if historySeeded && !historyDropped
                    loopSay(ctx, "[warn] provider rejected the conversation history — " *
                                 "retrying this turn without it")
                    historyDropped = true
                    historySeeded = false
                    # Rebuild the prompt as system + THIS run's own messages. snapIdx
                    # is a position in `messages`, so it shifts with the prefix.
                    keep = seededCount > 0 ? ctx.messages[(2 + seededCount):end] :
                                             ctx.messages[2:end]
                    ctx.messages = OllamaMessage[OllamaMessage(role = "system", content = AGENT_SYSTEM_PROMPT)]
                    append!(ctx.messages, keep)
                    snapIdx -= seededCount
                    try
                        out2 = withModelProgress(ctx, "waiting for the model (retry)") do
                            ctx.completeFn(ctx.messages)
                        end
                        flushThinking!(ctx)
                        out2
                    catch err2
                        loopSay(ctx, "[error] LLM call failed: " * sprint(showerror, err2))
                        ctx.onEvent(AgentFeedback(title = "Flooty Agent",
                                                  body = "LLM call failed: " *
                                                         sprint(showerror, err2),
                                                  kind = "warn",
                                                  sessionId = sessionIdFor(ctx.sess)))
                        finalReport!(ctx, "LLM call failed: " * sprint(showerror, err2))
                        break
                    end
                else
                    loopSay(ctx, "[error] LLM call failed: " * sprint(showerror, err))
                    ctx.onEvent(AgentFeedback(title = "Flooty Agent",
                                              body = "LLM call failed: " *
                                                     sprint(showerror, err),
                                              kind = "warn",
                                              sessionId = sessionIdFor(ctx.sess)))
                    finalReport!(ctx, "LLM call failed: " * sprint(showerror, err))
                    break
                end
            end
            # Visible background thinking: capture <thinking> BEFORE stripThinking
            # discards it, and stream it to the side panel.
            thinking = extractThinking(reply)
            if !reasoningRetried && !isempty(strip(thinking)) &&
               isempty(strip(stripProviderMarkup(stripThinking(reply))))
                reasoningRetried = true
                loopSay(ctx, "[retry] reasoning-only reply — encoding the intended action")
                retryReply = encodeActionFromThinking(ctx, thinking)
                if retryReply !== nothing
                    flushThinking!(ctx)
                    reply = retryReply
                    thinking = extractThinking(reply)
                elseif !reasoningProbeUsed
                    # The encoder can still reason without emitting content.
                    # Do not burn a warning/stop: take one bounded, safe probe
                    # so the next turn has real terminal state to act on.
                    reasoningProbeUsed = true
                    loopSay(ctx, "[retry] reasoning-only reply — running a bounded probe")
                    reply = "{\"action\":\"send\",\"code\":\"pwd && ls -la\"}"
                    thinking = ""
                end
            end
            if !isempty(thinking)
                shown = stripProviderMarkup(thinking)      # never show a provider's call syntax
                if !isempty(shown)
                    ev = AgentThinkingEvent(sessionIdFor(ctx.sess), String(shown))
                    # Streamed live already -> the page has it; never push twice.
                    ctx.streamedThinking ||
                        pushAgentEventToWindow(activeTerminalUiWebview(), ev)
                    recordAgentEvent!(ctx.conv, ev)
                end
            end
            # The turn as the PROVIDER will see it on the next request: content
            # without the inline <thinking> block, and the reasoning itself in
            # its own field (`thinking`), which `requestMessages` serializes
            # under the provider's `reasoningField`. Dropping it here made every
            # follow-up turn a model with amnesia about its own last step.
            # Keep exactly the PREVIOUS turn's reasoning in context: dropping
            # all of it made long runs forget their own plan, while re-sending
            # every old reasoning channel made the ShadowTerm driver repeat the same
            # paragraph for 20 turns and consumed output budget before the JSON
            # action. Older monologues are dropped; the UI transcript keeps all.
            for i in eachindex(ctx.messages)
                m = ctx.messages[i]
                if m.role == "assistant" && m.thinking !== nothing
                    ctx.messages[i] = OllamaMessage(role = m.role, content = m.content,
                        thinking = nothing, images = m.images, tool_calls = m.tool_calls,
                        tool_name = m.tool_name, tool_call_id = m.tool_call_id,
                        _type = m._type)
                end
            end
            push!(ctx.messages,
                  OllamaMessage(role = "assistant", content = stripThinking(reply),
                                thinking = isempty(thinking) ? nothing : String(thinking)))
            action = extractActionJson(stripThinking(reply))
            if action === nothing
                # The model answered in a provider's own tool-call syntax instead of
                # our JSON. Translate it (and say so) rather than stopping as
                # "unparseable" with an untouched terminal.
                native = extractProviderAction(reply)
                if native !== nothing
                    loopSay(ctx, "[turn $(ctx.result.turns + 1)] native tool call translated to " *
                                 string(get(native, "action", "?")) * ": " *
                                 first(string(get(native, "code", get(native, "keys",
                                                                     get(native, "summary", "")))), 80))
                    # The prose AROUND the call is what the model was saying — keep it
                    # in the chat (the markup itself is already gone).
                    prose = stripProviderMarkup(stripThinking(reply))
                    if !isempty(prose)
                        ev = AgentTextEvent(sessionIdFor(ctx.sess), String(prose))
                        pushAgentEventToWindow(activeTerminalUiWebview(), ev)
                        recordAgentEvent!(ctx.conv, ev)
                    end
                    action = native
                end
            end
            if action === nothing && jsonFailureKind(reply) === :truncated
                truncated = recoverTruncatedSend(reply)
                if truncated !== nothing
                    loopSay(ctx, "[turn $(ctx.result.turns + 1)] recovered a truncated " *
                                 "send: " * first(truncated, 120))
                    action = JSON3.read(JSON3.write(Dict("action" => "send",
                                                         "code" => truncated)))
                end
            end
            if action === nothing
                bare = recoverBareCommand(reply)
                if bare !== nothing
                    loopSay(ctx, "[turn $(ctx.result.turns + 1)] recovered a bare " *
                                 "command as send: " * first(bare, 120))
                    action = JSON3.read(JSON3.write(Dict("action" => "send",
                                                         "code" => bare)))
                end
            end
            if action === nothing
                # BYTE-FAITHFUL log: whitespace-flattening HIDES control
                # characters (e.g. a literal raw newline inside a JSON string,
                # which JSON rightly rejects) — escape_string makes them
                # visible so "why did this not parse" is answerable from the
                # transcript alone.
                rawShown = stripProviderMarkup(stripThinking(reply))
                isempty(strip(rawShown)) && (rawShown = String(reply))
                noteAgentParseFailure!(ctx.sess, first(rawShown, 300))
                warning = "[warn] unparseable model output (turn $(ctx.result.turns + 1)): " *
                          first(escape_string(rawShown), 200)
                loopSay(ctx, warning)
                unparseStreak += 1
                # The warning was only a UI status event; the model never saw
                # the harness's own diagnosis. Put it in context as a SYSTEM
                # warning, then apply the documented 3-strike stop instead of
                # looping to turn 95 with the same truncated reply.
                push!(ctx.messages, OllamaMessage(role = "system",
                    content = "HARNESS WARNING: " * warning *
                              "\nThis reply was not accepted. It must be exactly one JSON object."))
                # NO THREE-STRIKE STOP: the user wants the agent to keep
                # working while the monitors advise. The warning/hint below is
                # the steering; maxTurns/user/monitors remain the only stops.
                # Escalating corrective note: each strike names the exact
                # escape rule violated, so the note itself carries NEW
                # information instead of becoming the next thing to parrot.
                failure = jsonFailureKind(reply)
                hint = if failure === :truncated
                    "Your reply was CUT OFF before the JSON closed (a long " *
                    "`code` value hits the output limit). Keep one action " *
                    "SMALL: split the work into several `send` actions, each " *
                    "under " * string(SEND_MAX_CODE_CHARS) * " characters, and " *
                    "escape newlines as \\n — never as literal newlines."
                elseif failure === :prose
                    "You answered in PROSE. Emit ONLY the JSON object."
                elseif unparseStreak == 1
                    "Quote characters inside string values must be escaped " *
                    "as \\\" (e.g. Pkg.add(\\\"X\\\") not Pkg.add(\"X\")) " *
                    "and newlines as \\n."
                else
                    "You have now sent $(unparseStreak + 1) invalid replies " *
                    "in a row. Stop repeating the same shape — emit the " *
                    "SHORTEST possible object, e.g. " *
                    "{\"action\":\"done\",\"summary\":\"ok\"}."
                end
                push!(ctx.messages,
                      OllamaMessage(role = "user", content = "SYSTEM NOTE: your previous reply was not valid " *
                              "JSON. Reply with EXACTLY ONE JSON object and " *
                              "NOTHING else — no prose, no markdown fence, no " *
                              "bare command. Schema: " *
                              "{\"action\":\"send\",\"code\":\"<shell command>\"} " *
                              "or {\"action\":\"done\",\"summary\":\"<what happened>\"}. " *
                              hint))
                sleep(1.0)
                ctx.result.turns += 1
                continue
            end
            unparseStreak = 0                     # parse recovered — reset guard
            clearAgentParseFailure!(ctx.sess)

            kind = getstr(action, "action", "")
            ctx.result.turns += 1
            # Non-send repeat detection (see prevActionSig comment).
            actionSig = replace(string(JSON3.write(action)), r"\s+" => "")
            # SEND REPEAT SAFETY: the monitor note can be present and a weak
            # driver can still replay the same send forever (observed: 400
            # identical turns). Let two occurrences through (a legitimate
            # retry), then skip the third and stop after three skips. This is a
            # harness stop, not a monitor interrupt and not a Ctrl+C.
            if kind == "send"
                if actionSig == lastSendSig
                    sendRepeat += 1
                else
                    lastSendSig = actionSig
                    sendRepeat = 0
                    sendDuplicateSkips = 0
                end
                if sendRepeat >= 2
                    sendDuplicateSkips += 1
                    msg = "identical send repeated $(sendRepeat + 1) times; " *
                          "its output cannot change — choose a different command or done"
                    loopSay(ctx, "[loop-guard] " * msg)
                    push!(ctx.monitorNotesPending, msg)
                    if sendDuplicateSkips >= 3
                        finalReport!(ctx, "stopped after repeated identical sends")
                        break
                    end
                    continue
                end
            else
                lastSendSig = ""
                sendRepeat = 0
                sendDuplicateSkips = 0
            end
            # `wait` is deliberately NOT in this list: waiting IS the recovery
            # action when the pane is settling, and skipping it burns the turns
            # the model is trying to spend. Identical feedback/interrupt popups
            # are skipped, never deterministically stopped.
            if actionSig == prevActionSig &&
               kind in ("feedback", "interrupt")
                repeatStuck += 1
                loopSay(ctx, "[loop-guard] identical $kind action repeated " *
                             "($(repeatStuck)/3) — skipped")
                # Warp principle: harness steering must CARRY NEW INFORMATION
                # each time — a static nudge plus an unchanged snapshot makes
                # THIS message the next thing to parrot. So the note escalates
                # with the strike count and quotes the repeated action.
                push!(ctx.messages,
                      OllamaMessage(role = "user", content = "SYSTEM NOTE ($(repeatStuck)/3): you have now " *
                              "emitted this same action $(repeatStuck == 1 ?
                              "twice" : string(repeatStuck + 1, " times")) in " *
                              "a row and NOTHING changed in the terminal:
$actionSig
Repeating it can NEVER help — it produces no new output. Decide from the " *
                              "most recent ACTION RESULT above: if the eval " *
                              "ERRORED, send DIFFERENT corrected code (e.g. a " *
                              "fixed begin/end block); if the task is truly " *
                              "finished or impossible, finish with " *
                              "{\"action\":\"done\",\"summary\":\"...\"}."))
                continue                       # skip execution entirely
            end
            actionSig != prevActionSig && (repeatStuck = 0)
            prevActionSig = actionSig
            act = parseAction(action)
            outcome = performAction!(ctx, act, snap)
            outcome === :break && break
        end
    finally
        clearAgentParseFailure!(sess)
        publishTerminalStatus!(sess, "idle")
        # Preserve the FULL message list for a warm follow-up. The bounded
        # conversation seed remains the cold-start fallback.
        try storeRunContext!(conv, ctx.messages) catch end
        # Yield the REPL back unless the user already took it.
        currentState(sess.control) != :user && tagOut(sess.control)
    end
    if isempty(strip(ctx.result.summary)) && !ctx.result.ok
        finalReport!(ctx, "turn budget reached")
    end
    return ctx.result
end

_noopEvent(::Any) = nothing
