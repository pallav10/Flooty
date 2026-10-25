module Flooty

using Dates
using UUIDs
using SHA
using Base64
using Random
using FlootyPTYLayer
import FlootyAbstract
using FlootyAbstract: AbstractMessage, AbstractPersistable, AbstractPersistenceBackend
using FlootyBase: MessageItem
using FlootyStreams: OllamaMessage, OllamaToolCall, OllamaToolCallFunction
import FlootyStreams
using FlootyPTYLayer: ReplSession, startReplSession, agentWriteAndWait, closeSession!
using StructTypes
using JSON3
import FlootyPersistence
using FlootyPersistence: JSONBackend

include("conversation.jl")          # per-session transcript (the app owns it)
include("journal.jl")               # append-only event journal (SQLite now, Arrow later)
include("flootyOllamaClient.jl")
include("subscriptionStore.jl")
include("subscriptions.jl")
include("subscriptionCopilot.jl")
include("subscriptionClaude.jl")
include("subscriptionXai.jl")
include("slashCommands.jl")
include("promptDecision.jl")
include("context.jl")                # model window, usage tracking, compaction
include("flootyAgentTools.jl")
include("flootyAgentLoop.jl")
include("flootyAgentMonitor.jl")
include("flootyAgentRunner.jl")
include("sessions.jl")              # the session tree (root chat session)
include("chatOnly.jl")              # the conversation before any terminal exists
include("browserSession.jl")        # a live web panel + its driver
include("flootyTrajectoryMonitor.jl")
include("sessionReattach.jl")
include("userPreferences.jl")
include("logBridge.jl")             # @warn/@error -> chat transcript
include("app.jl")                   # the application: entry point + state

function __init__()
    # EVERY new terminal gets its own ambient monitor + standing agent —
    # including plain "+ New Terminal" tabs spawned from the PAGE (the UI
    # layer fires this hook for every session-backed terminal it creates).
    FlootyPTYLayer.addSessionTerminalHook!() do sess, parent_id, kind, remote
        try
            # The REQUESTING session is the parent (the root chat when the
            # page's plain "new terminal" asked); the tree is what traces/
            # steering use. A session the page launched WITHOUT a parent is a
            # ROOT of its own — the app boots with the chat session as the
            # default root, and Ctrl+Shift+R adds sibling roots.
            root = ensureRootChatSession!()
            pid = if isempty(parent_id)
                # The FIRST terminal of the chat-only boot adopts the chat's
                # thread (the conversation continues); a later one is a root.
                CHAT_THREAD_ADOPTED[] ? nothing : root.id
            else
                String(parent_id)
            end
            registerTerminalSession!(sess; parent_id = pid,
                                    kind = Symbol(kind), remote = String(remote))
            # The FIRST terminal adopts the chat-only conversation, so its agent
            # continues from what the user already discussed. Later terminals
            # start clean: a copied main chat made a new pane resume an earlier
            # task (e.g. "launch julia repl" leaking into an `ssh` task).
            if !CHAT_THREAD_ADOPTED[] && pid == root.id
                CHAT_THREAD_ADOPTED[] = true
                seedChatThreadInto!(sess)
                # The adopter's Chat rail IS the root thread. One watcher for
                # that surface, now keyed by the terminal id.
                migrateChatMonitor!(root.id,
                    FlootyPTYLayer.sessionIdFor(sess); note_key = sess)
            end
            startMonitor!(sess)
            startTrajectoryMonitor!(sess)
            startAgentRunner!(sess)
            @debug string("[flooty] auto-attached monitor + standing agent to " *
                    "new session (pid ", sess.pty.pid, ")")
        catch err
            @debug "Flooty: auto-attach failed" exception = err
        end
    end
    # The page's model picker: FlootyPTYLayer owns the bindings but knows nothing
    # about models, so the agent side answers for them.
    FlootyPTYLayer.addAgentModelHooks!(agentModelState, selectAgentModel,
                                       selectMonitorModel)
    FlootyPTYLayer.addSlashCommandHooks!(slashCommandCatalog, dispatchSlashCommand,
                                        subscriptionUiAction)
    FlootyPTYLayer.addChatOnlyHandler!(chatSessionTurn!)
    FlootyPTYLayer.addNewChatHandler!(newChatSessionHandler)
    FlootyPTYLayer.addChatCloseHandler!(closeChatSession!)
    FlootyPTYLayer.addNewBrowserHandler!(newBrowserSessionHandler)
    FlootyPTYLayer.addBrowserNavigateHandler!(browserNavigateHandler)
    FlootyPTYLayer.addChatSessionProvider!(function ()
        ensureRootChatSession!()
        return rootChatSession().id
    end)
    FlootyPTYLayer.addChatInteractionHandler!(chatInteractionTrace!)
    FlootyPTYLayer.addSessionTerminalCloseHook!(unlinkTerminalSession!)
    # The tree navigation's "make this my parent": the page moved the pane,
    # the app moves the session's edge so its tree agrees.
    FlootyPTYLayer.addSessionReparentHook!() do child_id, parent_id
        try
            setParent!(child_id, parent_id)
        catch err
            @debug "Flooty: re-parent failed" exception = err
        end
    end
    FlootyPTYLayer.addSessionReconnectHook!() do oldSess, newSess
        try
            reattachSession!(oldSess, newSess)
        catch err
            @warn "reconnect reattach failed" exception = err
        end
    end
end

export activateReplTool!, activeReplSession, deactivateReplTool!,
    AgentModelConfig, defaultAgentModelConfig, configureAgent!,
    chatCompletion, ollamaReachable, extractThinking,
    listAgentModels, agentModelState, selectAgentModel, selectMonitorModel,
    pushMonitorNote!, takeMonitorNotes!, setAgentBrief!, agentBriefFor,
    agentBriefPrompt, chatOnlyTurn!, seedChatThreadInto!,
    ChatSession, TerminalSession, BrowserSession, ensureRootChatSession!, rootChatSession,
    sessionForId, registerTerminalSession!, unlinkTerminalSession!,
    publishTerminalStatus!,
    SessionTrace, pushTraceToParent!, takeParentNotes!, steerSession!,
    sessionNode, childSessions, childTerminals, childTerminalAt, childChats,
    forwardSplitInsight!, forwardParentInsight!,
    chatInteractionTrace!, chatTurnMessages, CHAT_MONITOR_COMPLETE, CHAT_COMPLETE,
    TrajectoryConfig, TrajectoryMonitor,
    startTrajectoryMonitor!, stopTrajectoryMonitor!, trajectoryToolCall!,
    trajectoryToolResult!, trajectoryStatus!, trajectoryContext!, trajectoryTask!,
    noteUserMessage!, recordUserPreference!, preferencesContext, preferencesPath,
    preferenceProjectName, PREFERENCE_COMPLETE,
    promptStatusDecision, ps2TimeHazard, PROMPT_DECISION_STUB,
    parseChatReply, launchChatTerminal!, launchChildChat!, newRootChatSession!,
    newChatSessionHandler, closeChatSession!, launchBrowserSession!, newBrowserSessionHandler,
    browserNavigateHandler, browserTurnFor!, BROWSER_COMPLETE, chatTurnFor!,
    chatSessionTurn!, RUNNER_COMPLETE,
    Conversation, conversationFor, conversationKey, conversationContext,
    conversationTranscript, recordAgentEvent!, conversations, forgetConversation!,
    enableJournalPersistence!, disableJournalPersistence!, journalStore,
    journalSessionUid, journalBindSession!, journalAppend!, journalConversation,
    journalSessionList, journalDoctor, defaultJournalPath, JournalBinding,
    clearConversation!, ConversationData, conversationStore,
    enableConversationPersistence!, saveConversation!, saveConversations!,
    savedConversations, loadConversation,
    contextLengthFor, contextUsage, estimateTokens, compactMessages!, formatTokens,
    sessionModelConfig, setSessionModel!, forgetSessionModel!,
    CONTEXT_COMPACT_AT, CONTEXT_KEEP_LAST, DEFAULT_CONTEXT_LENGTH,
    AgentApp, agentApp, runAgentApp, appConversation, appConversations,
    runTerminalAgent!, lastAgentTranscript,
    startMonitor!, stopMonitor!, monitorRunning, MonitorConfig,
    AgentFeedback, TerminalSnapshot, agentSnapshot, inputTargetFor,
    InputTarget, pushPopup!,
    resolveSplitTarget,
    startAgentRunner!, stopAgentRunner!, agentRunnerRunning, agentRunnerBusy


const ACTIVE_SESSION = Ref{Union{Nothing, ReplSession}}(nothing)
const DEFAULT_SIDECAR = joinpath(".warp", "repl-status.md")
const DEFAULT_CMD = FlootyPTYLayer.defaultTerminalCmd()

# Process-wide agent configuration (models + endpoint).
const AGENT_CONFIG = Ref{AgentModelConfig}(defaultAgentModelConfig())
# Per-session transcripts (one agent per session => one transcript each);
# `_LAST_TRANSCRIPT_AT` orders them so the no-arg `lastAgentTranscript()`
# returns whichever session finished MOST RECENTLY.
const LAST_TRANSCRIPTS = IdDict{Any,Vector{String}}()
const _LAST_TRANSCRIPT_AT = IdDict{Any,Float64}()
const _TRANSCRIPTS_LOCK = ReentrantLock()

"""
    configureAgent!(; actorModel, monitorModel, baseUrl, apiKey) :: AgentModelConfig

Update the process-wide remote-model config. Unset kwargs keep current values.
"""
function configureAgent!(; actorModel::Union{Nothing,AbstractString} = nothing,
                         monitorModel::Union{Nothing,AbstractString} = nothing,
                         baseUrl::Union{Nothing,AbstractString} = nothing,
                         apiKey::Union{Nothing,AbstractString} = nothing)
    cfg = AGENT_CONFIG[]
    if actorModel !== nothing
        cfg.actorModel = String(actorModel)
    end
    if monitorModel !== nothing
        cfg.monitorModel = String(monitorModel)
    end
    if baseUrl !== nothing
        normalized = normalizeOllamaUrl(String(baseUrl))
        cfg.baseUrl = normalized === nothing ? cfg.baseUrl : normalized
    end
    if apiKey !== nothing
        cfg.apiKey = String(apiKey)
    end
    return cfg
end

function modelSessionForId(id::AbstractString)
    logical = sessionForId(id)
    logical isa Union{ChatSession,BrowserSession} && return logical
    logical isa TerminalSession && logical.repl !== nothing && return logical.repl
    return try
        FlootyPTYLayer.sessionForTerminalId(String(id))
    catch
        nothing
    end
end

"""
    agentModelState(sessionId = "") :: NamedTuple(current, available)

What the UI's model picker shows FOR ONE TAB: the model that tab's session runs
(`current`) and everything the endpoint offers (`available`). An empty/unknown
id answers with the process default, which is what a tab that never chose one
uses. Per-TAB models: two terminals can run different models at the same time.
"""
function agentModelState(sessionId::AbstractString = "")
    sess = modelSessionForId(sessionId)
    cfg = sess === nothing ? AGENT_CONFIG[] : sessionModelConfig(sess)
    # Non-blocking: bindings run on the UI's main thread (see availableAgentModels).
    return (current = cfg.actorModel,
            monitor = cfg.monitorModel,
            available = availableAgentModels())
end

"""
    selectMonitorModel(name, sessionId = "") :: NamedTuple(current, monitor, available)

Switch the AMBIENT MONITOR's model for that tab (or the process default). The actor
keeps its own model: the monitor runs short, frequent checks and is often better on
a different (cheaper or faster) model than the one driving the terminal.
"""
function selectMonitorModel(name::AbstractString, sessionId::AbstractString = "")
    sess = modelSessionForId(sessionId)
    if sess === nothing
        configureAgent!(monitorModel = String(name))
    else
        setSessionMonitorModel!(sess, String(name))
    end
    return agentModelState(String(sessionId))
end

"""
    selectAgentModel(name, sessionId = "") :: NamedTuple(current, available)

Switch the model FOR THAT TAB and report the resulting state. A run reads the
config when it STARTS, so the choice applies to the next commissioned task — the
one already running keeps the model it began with. Without a session id this
changes the process default (headless runs, and tabs that never chose one).
"""
function selectAgentModel(name::AbstractString, sessionId::AbstractString = "")
    sess = modelSessionForId(sessionId)
    if sess === nothing
        # The monitor has its OWN picker now: choosing an agent model must not
        # silently overwrite an explicit monitor choice.
        configureAgent!(actorModel = String(name))
    else
        setSessionModel!(sess, String(name))
        # The tab's transcript is tagged with the model that produced it.
        try
            conversationFor(sess isa ReplSession ? sess : sess.id).model = String(name)
        catch err
            @debug "selectAgentModel: conversation tag failed" exception = err
        end
    end
    return agentModelState(String(sessionId))
end

"""
Build the FlootySessions-compatible executor closure for `sess`.

Contract (`f(code)::String -> (Bool, String)`): run `code` through the PTY via
`agentWriteAndWait`; on success return `(true, raw terminal excerpt)`; on
failure return `(false, excerpt)` when the excerpt carries an "ERROR:" line,
otherwise synthesize `"ERROR: evaluation failed (<errorKind>)"` so downstream
tool consumers always see an actionable error string.
"""
function makeExecutor(sess::ReplSession, timeout::Float64)
    return function (code::String)
        outcome = agentWriteAndWait(sess, code; timeout = timeout)
        if outcome.ok
            return (true, outcome.excerpt)
        else
            msg = isempty(strip(outcome.excerpt)) ?
                "ERROR: evaluation failed ($(outcome.errorKind))" :
                outcome.excerpt
            if !occursin("ERROR:", msg)
                msg = "ERROR: " * msg
            end
            return (false, msg)
        end
    end
end

"""
    activateReplTool!(; cmd = defaultTerminalCmd(), timeout = 60.0,
                      rows = 24, cols = 80,
                      sidecarPath = ".warp/repl-status.md") :: ReplSession

Start a REAL PTY-backed REPL session running `cmd` (via `FlootyPTYLayer`),
store it module-side, and register it as the FlootySessions `repl` tool
executor, replacing the in-process `Core.eval` fallback.

Calling it twice closes and replaces the previous session.
The optional FlootySessions package must be installed in the active environment.
If it cannot load, the current session is left unchanged.
"""
function activateReplTool!(; cmd::Cmd = DEFAULT_CMD,
                           timeout::Real = 60.0,
                           rows::Int = 24,
                           cols::Int = 80,
                           sidecarPath::AbstractString = DEFAULT_SIDECAR)
    sessions = try
        Base.require(Base.PkgId(UUID("963c42d5-230d-4615-aa6e-0698ef3b700d"),
                                "FlootySessions"))
    catch err
        throw(ArgumentError("activateReplTool! requires the optional FlootySessions integration. " *
                            "Install the genuine FlootySessions package and its dependencies " *
                            "in the active Julia environment before activating the legacy REPL tool. " *
                            sprint(showerror, err)))
    end
    # Replace any previously active session (close the old one first).
    if ACTIVE_SESSION[] !== nothing
        try
            closeSession!(ACTIVE_SESSION[])
        catch
            # best effort: never block re-activation on teardown errors
        end
        ACTIVE_SESSION[] = nothing
    end

    waitPrompt = occursin(r"\bjulia\b|\bpython3?\b|\bipython3?\b|\bnode\b", string(cmd))
    sess = startReplSession(cmd; rows = rows, cols = cols,
                            sidecarPath = String(sidecarPath),
                            waitPrompt = waitPrompt)
    Base.invokelatest(sessions.set_repl_executor!, makeExecutor(sess, Float64(timeout)))
    ACTIVE_SESSION[] = sess
    return sess
end

"""
    activeReplSession() :: Union{Nothing, ReplSession}

The session installed by the most recent `activateReplTool!` call, or
`nothing` if none is active.
"""
activeReplSession() = ACTIVE_SESSION[]

"""
    deactivateReplTool!()

Close the active session (if any) and reset `FlootySessions.REPL_EXECUTOR`
back to `nothing`, restoring the in-process fallback executor.
Idempotent.
"""
function deactivateReplTool!()
    if ACTIVE_SESSION[] !== nothing
        try
            closeSession!(ACTIVE_SESSION[])
        catch
        end
        ACTIVE_SESSION[] = nothing
    end
    sessions = get(Base.loaded_modules,
                   Base.PkgId(UUID("963c42d5-230d-4615-aa6e-0698ef3b700d"), "FlootySessions"),
                   nothing)
    sessions === nothing || (sessions.REPL_EXECUTOR[] = nothing)
    return nothing
end

# ---- terminal-use agent entry points ------------------------------------------

"""
    runTerminalAgent!(sess_or_nothing, task::AbstractString;
                      maxTurns = 12, evalTimeoutS = 60.0,
                      onEvent = popupEventBridge, cmd = DEFAULT_CMD,
                      waitTimeoutS = 300.0) ->
                      NamedTuple(ok, turns, summary, transcript)

Run the autonomous terminal-use loop against `sess`. When called with
`nothing`, a fresh headless session is started first (and closed afterwards).
Events flow to `onEvent(::AgentFeedback)`; the default bridge pushes glass
popups into the live WebView UI (stdout fallback when no window). The final
transcript is also kept in `lastAgentTranscript()`.
"""
function runTerminalAgent!(sessOrNothing::Union{Nothing,ReplSession},
                           task::AbstractString;
                           maxTurns::Int = 0,
                           evalTimeoutS::Real = 60.0,
                           onEvent::Function = popupEventBridge,
                           completeFn::Union{Nothing,Function} = nothing,
                           cmd::Cmd = DEFAULT_CMD,
                           waitTimeoutS::Real = 300.0,
                           contextLimit::Integer = 0)
    owned = sessOrNothing === nothing
    sess = owned ? startReplSession(cmd) : sessOrNothing
    try
        result = runAgentLoop!(sess, task;
                               completeFn = completeFn,
                               maxTurns = maxTurns,
                               onEvent = onEvent,
                               evalTimeoutS = evalTimeoutS,
                               waitTimeoutS = waitTimeoutS,
                               contextLimit = contextLimit)
        lock(_TRANSCRIPTS_LOCK) do
            key = owned ? :owned : sess          # headless runs share one slot
            LAST_TRANSCRIPTS[key] = result.transcript
            _LAST_TRANSCRIPT_AT[key] = time()
        end
        return (ok = result.ok, turns = result.turns,
                summary = result.summary, transcript = result.transcript)
    finally
        owned && try
            closeSession!(sess)
        catch
        end
    end
end

"""
    lastAgentTranscript([sess]) :: Vector{String}

Per-session transcripts: with `sess`, THAT session's latest agent transcript
(concurrent agents never overwrite each other). Without, whichever session
finished most recently.
"""
function lastAgentTranscript(sess::Union{Nothing,ReplSession} = nothing)
    lock(_TRANSCRIPTS_LOCK) do
        if isempty(LAST_TRANSCRIPTS)
            return String[]
        elseif sess === nothing
            best = argmax(kv -> kv[2], _LAST_TRANSCRIPT_AT)[1]
            return copy(get(LAST_TRANSCRIPTS, best, String[]))
        else
            return copy(get(LAST_TRANSCRIPTS, sess, String[]))
        end
    end
end

"""
    popupEventBridge(fb::AgentFeedback)

Default event sink: WebView popup when the UI is live, stdout otherwise.
"""
popupEventBridge(fb::AgentFeedback) = defaultMonitorEventBridge!(fb)

"""
    pushPopup!(title, body; kind = "info")

Manually surface an agent popup (same channel the loop/monitor use).
"""
function pushPopup!(title::AbstractString, body::AbstractString;
                    kind::AbstractString = "info")
    defaultMonitorEventBridge!(
        AgentFeedback(title = String(title), body = String(body),
                      kind = String(kind)))
    return nothing
end

end # module Flooty
