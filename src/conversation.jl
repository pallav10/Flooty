# conversation.jl — the agent's per-session transcript, in the family's vocabulary.
#
# What this is FOR: an agent run used to start from an empty message list, so a
# second instruction in the same tab had no idea what the first one did (only what
# still happened to be on screen). The conversation is the record that fixes it —
# every event a run produces is appended here, and the next run is seeded with a
# bounded window of it.
#
# Shape, and why:
#   * entries are `FlootyBase.MessageItem` wrapping `FlootyStreams.OllamaMessage` —
#     the exact vocabulary FlootyTUI renders and FlootyApp streams, so a unified
#     front end needs no translation (role/content/thinking/tool_calls/tool_call_id
#     cover text, reasoning, a tool call and its result);
#   * a conversation is keyed by a SESSION ID string, not by a PTY. It therefore
#     knows nothing about terminals, which is what lets a BrowserSession (or any
#     future `AbstractTerminalSession`) own one unchanged;
#   * it speaks the session-layer message API (`FlootyAbstract.get_messages` /
#     `add_message!`), the same pair `FlootySessions.Session` implements, so callers
#     do not need to know which kind of session they hold.

"""
    Conversation(id)

One session's transcript: what was asked, what the agent said, reasoned, ran and
got back. Thread-safe (runs and the UI touch it from different tasks) and bounded
so a long-lived tab cannot grow without limit.
"""
mutable struct Conversation
    const id::String
    const messages::Vector{MessageItem}
    const lock::ReentrantLock
    const maxMessages::Int
    model::String
    agent::String
end

Conversation(id::AbstractString; maxMessages::Int = CONVERSATION_MAX_MESSAGES) =
    Conversation(String(id), MessageItem[], ReentrantLock(), maxMessages, "", "")

"Conversations that grew past the cap drop their OLDEST entries."
const CONVERSATION_MAX_MESSAGES = 400

# ---- registry ---------------------------------------------------------------
# Keyed by the id the UI already uses for a session (`FlootyPTYLayer.sessionIdFor`);
# a session with no UI id yet (headless probes, sessions created before a window
# exists) gets a stable key from its PTY, and the entry is re-keyed when the UI
# adopts it.
const CONVERSATIONS = Dict{String,Conversation}()
const CONVERSATIONS_LOCK = ReentrantLock()

"Stable key for `sess`: the UI's terminal id when adopted, else `pty-<pid>`."
function conversationKey(sess::ReplSession)::String
    id = FlootyPTYLayer.sessionIdFor(sess)
    isempty(id) || return id
    pid = try
        Int(sess.pty.pid)
    catch
        0
    end
    return string("pty-", pid)
end

"""
    conversationFor(id_or_session) :: Conversation

The conversation for a session id or a `ReplSession`, created on first use — and
restored from the app's persistence store when one was saved under that id.
"""
function conversationFor(id::AbstractString)::Conversation
    key = String(id)
    held = lock(() -> get(CONVERSATIONS, key, nothing), CONVERSATIONS_LOCK)
    held === nothing || return held
    # Restoring reads the store, so it happens OUTSIDE the registry lock; the
    # second lock keeps a concurrent first use from yielding two objects.
    restored = loadConversation(key)
    return lock(() -> get!(() -> restored, CONVERSATIONS, key), CONVERSATIONS_LOCK)
end

conversationFor(sess::ReplSession) = conversationFor(conversationKey(sess))

"Every conversation currently held (for inspection/teardown)."
conversations() = lock(() -> collect(values(CONVERSATIONS)), CONVERSATIONS_LOCK)

"""
    forgetConversation!(id)

Drop a session's conversation AND delete its stored transcript — the "delete
this session" operation. Terminating a tab does NOT call this: a transcript
outliving its PTY is the whole point of the store.
"""
function forgetConversation!(id::AbstractString)
    key = String(id)
    lock(() -> pop!(CONVERSATIONS, key, nothing), CONVERSATIONS_LOCK)
    backend = CONVERSATION_STORE[]
    backend === nothing || FlootyAbstract.delete!(backend, ConversationData, key)
    return nothing
end

# ---- the session-layer message API -----------------------------------------
# Same functions `FlootySessions.Session` implements, so a caller can hold either.
FlootyAbstract.get_messages(conv::Conversation) =
    lock(() -> copy(conv.messages), conv.lock)

"""
    add_message!(conv, msg; model = "", agent = "")

Append one message, wrapped in the protocol's `MessageItem` (timestamped, tagged
with the model that produced it). Oldest entries are dropped past the cap.
"""
function FlootyAbstract.add_message!(conv::Conversation, msg::FlootyAbstract.AbstractMessage;
                                     model::AbstractString = "", agent::AbstractString = "")
    item = MessageItem(msg, now(), String(model), String(agent))
    lock(conv.lock) do
        push!(conv.messages, item)
        overflow = length(conv.messages) - conv.maxMessages
        overflow > 0 && deleteat!(conv.messages, 1:overflow)
    end
    saveConversation!(conv)      # write-through: a turn is never lost to a crash
    return item
end

"Empty the transcript (keeps the conversation object, and its id)."
function clearConversation!(conv::Conversation)
    try clearCachedRunContext!(conv) catch end
    lock(conv.lock) do
        empty!(conv.messages)
    end
    saveConversation!(conv)
    return conv
end

# ---- recording what a run does ----------------------------------------------
"""
    recordAgentEvent!(conv, ev::AbstractAgentEvent; model, agent)
    recordTask!(conv, task; model, agent)

Append one run event, mapped onto the family's message vocabulary:

| event                  | becomes                                                     |
| `AgentTextEvent`       | `role = "assistant"`, `content`                             |
| `AgentThinkingEvent`   | `role = "assistant"`, `thinking`                            |
| `AgentToolCallEvent`   | `role = "assistant"`, one `tool_calls` entry (+`tool_name`) |
| `AgentToolResultEvent` | `role = "tool"`, `content`, `tool_call_id`                  |

`AgentStatusEvent` (turns, guards, stops) is status bookkeeping and stays out of
the history; `recordTask!` is the instruction that commissioned the run.
"""
function recordAgentEvent!(conv::Conversation, ev::AgentTextEvent;
                           model::AbstractString = conv.model,
                           agent::AbstractString = conv.agent)
    msg = OllamaMessage(role = "assistant", content = ev.text)
    item = FlootyAbstract.add_message!(conv, msg; model = model, agent = agent)
    journalAppend!(conv; kind = "assistant_text", role = "assistant",
                   content = ev.text)
    return item
end

function recordAgentEvent!(conv::Conversation, ev::AgentThinkingEvent;
                           model::AbstractString = conv.model,
                           agent::AbstractString = conv.agent)
    msg = OllamaMessage(role = "assistant", thinking = ev.text)
    item = FlootyAbstract.add_message!(conv, msg; model = model, agent = agent)
    journalAppend!(conv; kind = "assistant_thinking", role = "assistant",
                   thinking = ev.text)
    return item
end

function recordAgentEvent!(conv::Conversation, ev::AgentToolCallEvent;
                           model::AbstractString = conv.model,
                           agent::AbstractString = conv.agent)
    call = OllamaToolCall(OllamaToolCallFunction(ev.tool,
                                                 Dict{String,Any}("detail" => ev.detail)),
                          isempty(ev.id) ? nothing : ev.id)
    msg = OllamaMessage(role = "assistant", content = ev.detail, tool_name = ev.tool,
                        tool_calls = [call])
    item = FlootyAbstract.add_message!(conv, msg; model = model, agent = agent)
    journalAppend!(conv; kind = "tool_call", role = "assistant",
                   content = ev.detail, tool_name = ev.tool, tool_call_id = ev.id)
    return item
end

function recordAgentEvent!(conv::Conversation, ev::AgentToolResultEvent;
                           model::AbstractString = conv.model,
                           agent::AbstractString = conv.agent)
    msg = OllamaMessage(role = "tool", content = ev.detail,
                        tool_call_id = isempty(ev.id) ? nothing : ev.id)
    item = FlootyAbstract.add_message!(conv, msg; model = model, agent = agent)
    journalAppend!(conv; kind = "tool_result", role = "tool",
                   content = ev.detail, ok = ev.ok,
                   tool_call_id = isempty(ev.id) ? nothing : ev.id)
    return item
end

function recordTask!(conv::Conversation, task::AbstractString;
                     model::AbstractString = conv.model,
                     agent::AbstractString = conv.agent)
    msg = OllamaMessage(role = "user", content = String(task))
    item = FlootyAbstract.add_message!(conv, msg; model = model, agent = agent)
    # Mirror into the event journal (no-op while journaling is off). The journal is
    # the durable half: this instruction becomes a `user_instruction` row that a
    # later session load filters out of the timeline.
    journalAppend!(conv; kind = "user_instruction", role = "user",
                   content = String(task))
    return item
end

# ---- history: what the next run is given ------------------------------------
"""
    conversationContext(conv; maxChars = 80_000, maxMessages = 1000) :: Vector{OllamaMessage}

The bounded tail of the conversation as `role`/`content` messages — what a run is
seeded with so a follow-up instruction can see what the previous one did. Cuts from
the OLDEST end first (message count, then characters) so the most recent work is
always intact.

PROVIDER CONTRACT: a `tool` role message is only legal when the assistant message it
answers carries a resolvable tool CALL, which this flat seeded shape does not
express — Beam rejects exactly that ("tool message … has no resolvable tool name").
So a call and its result are folded into ONE assistant message here (`ran send: pwd`
/ `→ /Users/…`), and `tool` entries never appear in the seeded context.
"""
function conversationContext(conv::Conversation;
                             maxChars::Int = 80_000,
                             maxMessages::Int = 1000,
                             maxPieceChars::Int = 8_000)::Vector{OllamaMessage}
    items = lock(() -> copy(conv.messages), conv.lock)
    length(items) > maxMessages && (items = items[end-maxMessages+1:end])
    rendered = _renderForModel(items; maxPieceChars = maxPieceChars)
    out = OllamaMessage[]
    budget = maxChars
    for piece in reverse(rendered)
        cost = length(piece.content) + length(piece.thinking) + 1
        cost > budget && break
        budget -= cost
        push!(out, OllamaMessage(role = piece.role, content = piece.content,
                                 thinking = isempty(piece.thinking) ? nothing :
                                            piece.thinking))
    end
    reverse!(out)
    omitted = length(rendered) - length(out)
    if omitted > 0 && maxChars >= 1000
        pushfirst!(out, OllamaMessage(role = "user",
            content = "[earlier transcript omitted: " * string(omitted) *
                      " messages no longer fit the seed budget; re-derive " *
                      "current state from the terminal snapshot]"))
    end
    return out
end

"""
Conversation entries for the model as `(role, content, thinking)` pieces: tool
results folded into the call that asked for them, each piece bounded.

TWO CHANNELS, and they must not be confused:
  * `content` never carries reasoning — re-feeding monologue as prose inflates the
    prompt and biases the next reply toward more monologue (measured: empty
    content three turns running, the run stopped "unparseable"), and
  * `thinking` carries it VERBATIM, to be serialized in the provider's own
    reasoning field (`requestMessages`, `AgentModelConfig.reasoningField`). The
    model gets its own reasoning back in the channel it was produced in; the user
    gets the same text in `conversationTranscript`.
An assistant turn that was pure reasoning therefore contributes `content = ""`
plus its `thinking`, not an empty message: the request keeps the reasoning
without a fake prose line.
"""
function _renderForModel(items::Vector{MessageItem};
                         maxPieceChars::Int = 400)
    out = NamedTuple{(:role, :content, :thinking),Tuple{String,String,String}}[]
    for item in items
        msg = item.message
        msg isa OllamaMessage || continue
        think = (msg.role == "assistant" && msg.thinking !== nothing) ?
                String(msg.thinking) : ""
        if msg.role == "tool"
            # Fold into the assistant message that asked for it (never a `tool` role).
            text = _clipResult(_messageText(msg; includeThinking = false), maxPieceChars)
            isempty(text) && continue
            if !isempty(out) && out[end].role == "assistant"
                prev = out[end]
                out[end] = (role = prev.role, content = prev.content * "\n→ " * text,
                            thinking = prev.thinking)
            else
                push!(out, (role = "user", content = "(tool result) " * text, thinking = ""))
            end
            continue
        end
        text = _clipResult(_messageText(msg; includeThinking = false), maxPieceChars)
        # A reasoning-only turn has NO content: never seed it as an EMPTY assistant
        # message. That is what the model saw as "user → assistant() → assistant()"
        # and it reads as if its recent turns were lost; the reasoning stays in the
        # transcript for the UI, and the actionable state is the snapshot + results.
        # Reasoning is still attached to turns that DO carry content.
        isempty(text) && continue
        push!(out, (role = String(msg.role), content = text, thinking = think))
    end
    return out
end

"Keep the informative end of a piece (command output arrives last, after the echo)."
function _clipResult(text::AbstractString, maxChars::Int)::String
    s = String(text)
    length(s) <= maxChars && return s
    return "…" * String(last(s, maxChars - 1))
end

"""
    _messageText(msg; includeThinking = false) -> String

One message as text: its content, optionally its reasoning, and any tool calls it
carries.

Reasoning is opt-IN because this function feeds BOTH views and they disagree:
  * the MODEL's seed (`conversationContext`) must never carry it — re-feeding the
    model its own monologue inflates the prompt and biases the next reply toward
    more monologue (measured: empty content three turns running, run stopped
    "unparseable"),
  * the HUMAN view (`conversationTranscript`, the page chat) must carry it, since
    that is what the user is watching.
A caller that wants the model-facing view therefore gets the safe answer by
default, and the UI opts in explicitly.
"""
function _messageText(msg::OllamaMessage; includeThinking::Bool = false)::String
    parts = String[]
    !isempty(something(msg.content, "")) && push!(parts, String(msg.content))
    if includeThinking
        thinking = something(msg.thinking, "")
        isempty(thinking) || push!(parts, "(reasoning) " * String(thinking))
    end
    if msg.tool_calls !== nothing
        for call in msg.tool_calls
            push!(parts, "ran " * call.function_.name * ": " *
                         string(get(call.function_.arguments, "detail", "")))
        end
    end
    return join(parts, "\n")
end

"""
    conversationTranscript(conv) -> Vector{String}

Human-readable transcript (probes, logs, the session tail view) — reasoning
INCLUDED, because this is the view a person reads, not the one a model is fed.
"""
function conversationTranscript(conv::Conversation)::Vector{String}
    [string(item.message.role, ": ",
            first(replace(_messageText(item.message; includeThinking = true), r"\s+" => " "), 160))
     for item in FlootyAbstract.get_messages(conv)]
end

# ---- persistence: the family's store, not a private file format -------------
# Transcripts persist through FlootyPersistence's backend (JSON3 + StructTypes;
# the app's own wire/action JSON also goes through JSON3)
# under `~/.flooty/conversations` — the same backend, DTO split and root the
# family uses for sessions. A SIBLING directory rather than the shared
# `~/.flooty/sessions`: the backend keys records by id alone, so two record types
# in one directory would collide and each `list` would hand back the other's
# files.
#
# The APP owns the store (see `agentApp`). Headless `runTerminalAgent!` runs keep
# their transcript in memory only, so probes stay hermetic and never write to the
# user's home directory.

"""
    ConversationData <: AbstractPersistable

Serializable snapshot of one transcript — the DTO split `FlootySessions` uses for
`Session`/`SessionData`. `MessageItem` carries its own `StructTypes` definition
and discriminates the wrapped message by its `_type` field, so the round-trip is
the family's, not an ad-hoc encoder's.
"""
mutable struct ConversationData <: AbstractPersistable
    id::String
    model::String
    agent::String
    updated_at::DateTime
    messages::Vector{MessageItem}
    # `StructTypes.Mutable` needs a no-arg constructor (it fills fields in place).
    # Defining ANY inner constructor suppresses the compiler's full positional
    # one, so it is spelled out here: `ConversationData(conv)` builds every
    # snapshot through it, and without it every write-through threw
    # `MethodError: no method matching ConversationData(::String, …)` — which
    # killed the agent run on its FIRST recorded message, i.e. the pane was
    # handed straight back to the user after they submitted a prompt.
    ConversationData() = new("", "", "", now(), MessageItem[])
    ConversationData(id::String, model::String, agent::String, updated_at::DateTime,
                     messages::Vector{MessageItem}) =
        new(id, model, agent, updated_at, messages)
end

StructTypes.StructType(::Type{ConversationData}) = StructTypes.Mutable()

ConversationData(conv::Conversation) =
    ConversationData(conv.id, conv.model, conv.agent, now(),
                     FlootyAbstract.get_messages(conv))

"Rebuild a live conversation from its snapshot (the message cap re-applied)."
function Conversation(data::ConversationData)
    conv = Conversation(data.id)
    conv.model = data.model
    conv.agent = data.agent
    lock(conv.lock) do
        append!(conv.messages, data.messages)
        overflow = length(conv.messages) - conv.maxMessages
        overflow > 0 && deleteat!(conv.messages, 1:overflow)
    end
    return conv
end

"The default store: the family's `.flooty` root, one JSON file per transcript."
defaultConversationStore() =
    JSONBackend(joinpath(homedir(), ".flooty", "conversations"))

# `nothing` = persistence off; only the app turns it on (see `agentApp`).
const CONVERSATION_STORE = Ref{Union{Nothing,AbstractPersistenceBackend}}(nothing)

"Where transcripts are persisted, or `nothing` while persistence is off."
conversationStore() = CONVERSATION_STORE[]

"""
    enableConversationPersistence!([dir]) :: AbstractPersistenceBackend

Turn transcript persistence on for this process; `dir` overrides the store
(default `~/.flooty/conversations`). `agentApp` enables it on start.
"""
function enableConversationPersistence!(dir::Union{Nothing,AbstractString} = nothing)
    backend = dir === nothing ? defaultConversationStore() : JSONBackend(String(dir))
    CONVERSATION_STORE[] = backend
    return backend
end

"""
    saveConversation!(conv) -> Nothing

Store this transcript's snapshot (no-op while persistence is off).

A store failure is LOGGED, never thrown: the write-through runs inside the agent
run (`add_message!` on the first recorded turn), so anything that escape here
aborts the run and hands the pane back to the user with no work done. A missing
transcript is a side-record problem; a dead run is the user's problem.
"""
function saveConversation!(conv::Conversation)
    backend = CONVERSATION_STORE[]
    backend === nothing && return nothing
    try
        FlootyAbstract.save!(backend, ConversationData(conv))
    catch err
        @error "flooty: transcript write-through failed (run continues)" conv = conv.id exception = err
    end
    return nothing
end

"Force-save every held transcript (the app's `save_sessions` equivalent)."
function saveConversations!()
    backend = CONVERSATION_STORE[]
    backend === nothing && return 0
    saved = 0
    for conv in conversations()
        FlootyAbstract.save!(backend, ConversationData(conv))
        saved += 1
    end
    return saved
end

"""
    savedConversations() :: Vector{ConversationData}

Every transcript the store holds, newest first — what a session picker lists and
`conversationFor(id)` restores from.
"""
function savedConversations()::Vector{ConversationData}
    backend = CONVERSATION_STORE[]
    backend === nothing && return ConversationData[]
    data = FlootyAbstract.list(backend, ConversationData)
    sort!(data; by = d -> d.updated_at, rev = true)
    return data
end

"The stored transcript for `id`, or a fresh empty one (does not register it)."
function loadConversation(id::AbstractString)::Conversation
    backend = CONVERSATION_STORE[]
    if backend !== nothing
        data = FlootyAbstract.load(backend, ConversationData, String(id))
        data === nothing || return Conversation(data)
    end
    return Conversation(String(id))
end
