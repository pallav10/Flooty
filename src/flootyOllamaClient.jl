# flootyOllamaClient.jl — inference client for the Flooty agent.
#
# Talks an OpenAI-compatible inference endpoint (default: Poolside AI)
# (/v1/chat/completions, non-streaming). Models and endpoint are
# user-configurable via env vars with a remote default:
#   base URL = https://inference.poolside.ai/v1
#   actor   model = configurable via FLOOTY_ACTOR_MODEL
#   monitor model = configurable via FLOOTY_MONITOR_MODEL
#   api key  = configurable via FLOOTY_API_KEY
#
# Everything downstream takes an injectable `completeFn(messages)::String`
# so probes run deterministically WITHOUT a live endpoint; these helpers
# are just the default implementation of that seam.
#
using HTTP
using BufferedStreams: BufferedInputStream
import FlootyStreams
|
"""
Config for remote agent models. Construct via `defaultAgentModelConfig()` so
env overrides (`FLOOTY_INFERENCE_URL`, `FLOOTY_ACTOR_MODEL`,
`FLOOTY_MONITOR_MODEL`, `FLOOTY_API_KEY`) are honored; fields stay mutable
for `configureAgent!`.
"""
Base.@kwdef mutable struct AgentModelConfig
    baseUrl::String = "http://127.0.0.1:11434/v1"
    actorModel::String = "minimax-m3.1-flash:cloud"
    monitorModel::String = "minimax-m3.1-flash:cloud"
    apiKey::String = ""
    # Which JSON field carries an assistant turn's REASONING on the REQUEST side.
    # Providers disagree (Poolside/OpenRouter `reasoning`, DeepSeek
    # `reasoning_content`, Ollama `thinking`); "" disables it. The response side
    # already reads all three back — see `providerReasoning` — so the request side
    # is the only half that needs configuring.
    reasoningField::String = "reasoning"
    # Output budget per completion. Thinking models spend tokens on reasoning
    # BEFORE the JSON action; a small default truncated the action mid-string
    # (ShadowTerm run: five "unparseable" turns in a row, then a 3-strike stop).
    maxOutputTokens::Int = 4096
end
|
const DEFAULT_BASE_URL = "http://127.0.0.1:11434/v1"
const DEFAULT_ACTOR_MODEL = "minimax-m3.1-flash:cloud"
const DEFAULT_MONITOR_MODEL = "minimax-m3.1-flash:cloud"
const DEFAULT_API_KEY = ""
const DEFAULT_REASONING_FIELD = "reasoning"
|
function defaultAgentModelConfig()
    return AgentModelConfig(
        baseUrl = something(normalizeOllamaUrl(get(ENV, "FLOOTY_INFERENCE_URL", "")),
                            DEFAULT_BASE_URL),
        actorModel = something(nonempty(get(ENV, "FLOOTY_ACTOR_MODEL", "")),
                               DEFAULT_ACTOR_MODEL),
        monitorModel = something(nonempty(get(ENV, "FLOOTY_MONITOR_MODEL", "")),
                                 DEFAULT_MONITOR_MODEL),
        apiKey = something(nonempty(get(ENV, "FLOOTY_API_KEY", "")),
                           DEFAULT_API_KEY),
        # `FLOOTY_REASONING_FIELD` distinguishes "unset" from "explicitly empty":
        # empty means do not send reasoning at all (strict endpoints).
        reasoningField = haskey(ENV, "FLOOTY_REASONING_FIELD") ?
                         String(ENV["FLOOTY_REASONING_FIELD"]) : DEFAULT_REASONING_FIELD,
        maxOutputTokens = something(tryparse(Int, get(ENV, "FLOOTY_MAX_OUTPUT_TOKENS", "")),
                                   4096),
    )
end
|
nonempty(s::AbstractString) = isempty(strip(s)) ? nothing : String(strip(s))
|
# Accept bare root URLs and ones already ending in /v1; always yield root/v1.
function normalizeOllamaUrl(s::AbstractString)
    s = strip(s)
    isempty(s) && return nothing
    s = String(s)
    endswith(s, "/") && (s = chop(s))
    endswith(s, "/v1") || (s *= "/v1")
    return s
end
|
"""
    requestMessages(messages::Vector{OllamaMessage};
                    reasoningField = DEFAULT_REASONING_FIELD) :: Vector{Dict{String,Any}}

The OpenAI-compatible WIRE form of an agent conversation. Three details are
load-bearing:

  * `content` is ALWAYS a string. A reply that was nothing but provider-side
    reasoning strips to empty content (`stripThinking`), and
    `StructTypes.omitempties(::Type{OllamaMessage})` then DROPS the field —
    the endpoint reads a nil content and answers
    `400 invalid message content type: <nil>`, which kills the run on the turn
    right after the model thinks without acting (and the pane is handed back to
    the user before any work happens).
  * REASONING IS SERIALIZED, under the provider's own field name (`reasoning`,
    `reasoning_content`, `thinking` — `reasoningField`, disabled by ""). An
    assistant turn's `thinking` is its own channel, so it travels as that field
    and never as prose inside `content` (re-feeding reasoning as text inflates
    the prompt and biases the next reply toward monologue). Verified against the
    live endpoint: all three names are accepted, none is required.
  * the internal `_type` tag stays OFF the wire: it is bookkeeping.

`tool_calls`/`tool_name`/`tool_call_id` are forwarded when present so native
tool-call turns survive the round trip.
"""
function requestMessages(messages::Vector{OllamaMessage};
                         reasoningField::AbstractString = DEFAULT_REASONING_FIELD
                         )::Vector{Dict{String,Any}}
    thinkKey = String(reasoningField)
    wire = Vector{Dict{String,Any}}(undef, length(messages))
    for (i, m) in enumerate(messages)
        d = Dict{String,Any}(
            "role" => String(m.role),
            "content" => (m.content === nothing ? "" : String(m.content)),
        )
        if !isempty(thinkKey) && m.thinking !== nothing && !isempty(strip(m.thinking))
            d[thinkKey] = String(m.thinking)
        end
        m.tool_calls === nothing || (d["tool_calls"] = m.tool_calls)
        m.tool_name === nothing || (d["tool_name"] = m.tool_name)
        m.tool_call_id === nothing || (d["tool_call_id"] = m.tool_call_id)
        wire[i] = d
    end
    return wire
end

"""
    chatCompletion(baseUrl, model, messages::Vector{OllamaMessage}; temperature = 0.2,
                   apiKey = "", timeoutS = 120.0) :: String

One non-streaming chat round-trip against an OpenAI-compatible endpoint.
If `apiKey` is non-empty, an `Authorization: Bearer <key>` header is sent.
Messages go through `requestMessages` (not serialization of message structs,
which may omit empty `content` and produce an invalid request).
Returns the assistant message content string; throws on HTTP/transport
failure so callers decide retry policy.
"""
function chatCompletion(baseUrl::AbstractString, model::AbstractString,
                        messages::Vector{OllamaMessage};
                        temperature::Real = 0.2, apiKey::AbstractString = "",
                        timeoutS::Real = 120.0,
                        reasoningField::AbstractString = DEFAULT_REASONING_FIELD,
                        maxTokens::Integer = 4096, jsonMode::Bool = false)
    url = rtrimSlash(baseUrl) * "/chat/completions"
    bodyDict = Dict{String,Any}(
        "model" => String(model),
        "messages" => requestMessages(messages; reasoningField = reasoningField),
        "temperature" => Float64(temperature),
        "max_tokens" => Int(maxTokens),
        "stream" => false,
    )
    jsonMode && (bodyDict["response_format"] = Dict("type" => "json_object"))
    body = JSON3.write(bodyDict)
    headers = ["Content-Type" => "application/json"]
    if !isempty(apiKey)
        push!(headers, "Authorization" => "Bearer " * String(apiKey))
    end
    resp = HTTP.post(url, headers, body;
                     readtimeout = Int(timeoutS * 1000), retry = false)
    parsed = JSON3.read(String(resp.body))
    message = parsed.choices[1].message
    content = message.content === nothing ? "" : String(message.content)
    return withReasoning(content, providerReasoning(message))
end

"""
    providerReasoning(message) :: String

Reasoning an OpenAI-compatible endpoint returns in a field of its OWN instead of
inline in the content: `reasoning` (Poolside/Ollama cloud), `reasoning_content`
(DeepSeek-style), or Ollama's native `thinking`. Empty when the reply carries
none. Dropping these was why "thinking" never reached the UI on models that
reason without emitting `<thinking>` tags.
"""
function providerReasoning(message)::String
    for field in ("reasoning", "reasoning_content", "thinking")
        raw = get(message, Symbol(field), nothing)
        raw === nothing && continue
        text = String(raw)
        isempty(strip(text)) || return text
    end
    return ""
end

"""
    withReasoning(content, reasoning) -> String

Fold provider-side reasoning into the INLINE `<thinking>…</thinking>` convention
the rest of the agent already speaks (`extractThinking` shows it in the UI,
`stripThinking` keeps it out of the action JSON) so reasoning reaches the chat
whichever field the endpoint used. Content that already carries a thinking block
wins; a stray closing tag inside the reasoning is dropped so it cannot end the
block early.
"""
function withReasoning(content::AbstractString, reasoning::AbstractString)
    isempty(strip(reasoning)) && return String(content)
    occursin("<thinking>", content) && return String(content)
    safe = replace(String(reasoning), "</thinking>" => "")
    return "<thinking>" * safe * "</thinking>\n" * String(content)
end
|
# ---- available-model list (cached, refreshed OFF the UI thread) --------------
# `listAgentModels` does HTTP. Webviews BINDINGS run on the main thread inside the
# Cocoa loop, where a synchronous request can stall the whole window (observed:
# the picker's change handler never returned). Bindings therefore read this cache
# and a background task refreshes it.
const MODEL_LIST_CACHE = Ref{Vector{String}}(String[])
const MODEL_LIST_AT = Ref(0.0)
const MODEL_LIST_LOCK = ReentrantLock()
const MODEL_LIST_TTL = 60.0

"""
    availableAgentModels(; refresh = false) :: Vector{String}

The endpoint's model list, from cache (refreshed in a background task when stale
or when `refresh` is set). Never blocks: an empty list on the first call is fine,
the UI simply populates a moment later.
"""
function refreshAgentModels!(cfg::AgentModelConfig = AGENT_CONFIG[])
    refreshConnectedSubscriptionModels!()
    @async begin
        list = listAgentModels(cfg)
        lock(MODEL_LIST_LOCK) do
            MODEL_LIST_CACHE[] = list
            MODEL_LIST_AT[] = time()
        end
        return nothing
    end
    return nothing
end

function availableAgentModels(; refresh::Bool = false)::Vector{String}
    cached, age = lock(MODEL_LIST_LOCK) do
        (copy(MODEL_LIST_CACHE[]), MODEL_LIST_AT[] == 0 ? Inf : time() - MODEL_LIST_AT[])
    end
    (refresh || age > MODEL_LIST_TTL) && refreshAgentModels!()
    return sort!(unique!(vcat(cached, availableSubscriptionModels())))
end

# ---- per-tab models ---------------------------------------------------------
# ONE process, MANY tabs: each live session may run a different model. The
# process default (AGENT_CONFIG[]) stays the fallback for sessions that never
# chose one, and for headless runs.
const MODEL_BY_SESSION = IdDict{Any,AgentModelConfig}()
const MODEL_BY_SESSION_LOCK = ReentrantLock()

"Model configuration for `sess`: its own choice, else the process default."
function sessionModelConfig(sess)::AgentModelConfig
    return lock(MODEL_BY_SESSION_LOCK) do
        get(MODEL_BY_SESSION, sess, AGENT_CONFIG[])
    end
end

"Pin the AMBIENT MONITOR of `sess` to `model`; the actor keeps its own model."
function setSessionMonitorModel!(sess, model::AbstractString)::AgentModelConfig
    base = sessionModelConfig(sess)
    cfg = AgentModelConfig(baseUrl = base.baseUrl, actorModel = base.actorModel,
                           monitorModel = String(model), apiKey = base.apiKey,
                           reasoningField = base.reasoningField, maxOutputTokens = base.maxOutputTokens)
    lock(MODEL_BY_SESSION_LOCK) do
        MODEL_BY_SESSION[sess] = cfg
    end
    return cfg
end

"Pin `sess` to `model` (name from the picker); returns the config in force."
function setSessionModel!(sess, model::AbstractString)::AgentModelConfig
    base = sessionModelConfig(sess)
    cfg = AgentModelConfig(baseUrl = base.baseUrl, actorModel = String(model),
                           monitorModel = base.monitorModel, apiKey = base.apiKey,
                           reasoningField = base.reasoningField, maxOutputTokens = base.maxOutputTokens)
    lock(MODEL_BY_SESSION_LOCK) do
        MODEL_BY_SESSION[sess] = cfg
    end
    return cfg
end

"Drop `sess`'s per-tab choice (teardown); no-op when it never had one."
function forgetSessionModel!(sess)
    lock(MODEL_BY_SESSION_LOCK) do
        pop!(MODEL_BY_SESSION, sess, nothing)
    end
    return nothing
end

"""
    listAgentModels(cfg::AgentModelConfig = defaultAgentModelConfig()) :: Vector{String}

Model ids the endpoint offers (`GET /v1/models`), sorted. Best-effort: an
unreachable endpoint or an unexpected payload yields an empty list, so the UI's
picker simply has nothing to offer instead of erroring.
"""
function listAgentModels(cfg::AgentModelConfig = defaultAgentModelConfig())::Vector{String}
    url = rtrimSlash(cfg.baseUrl) * "/models"
    headers = Pair{String,String}[]
    isempty(cfg.apiKey) ||
        push!(headers, "Authorization" => "Bearer " * cfg.apiKey)
    try
        resp = HTTP.get(url, headers; readtimeout = 15_000, retry = false)
        parsed = JSON3.read(String(resp.body))
        ids = String[]
        for m in get(parsed, :data, ())
            id = get(m, :id, nothing)
            (id === nothing || isempty(strip(String(id)))) && continue
            push!(ids, String(id))
        end
        return sort!(ids)
    catch err
        @debug "flootyOllamaClient: listAgentModels failed" exception = err
        return String[]
    end
end

rtrimSlash(s::AbstractString) =
    endswith(s, "/") ? String(chop(s)) : String(s)
|
"""
    stripThinking(text) -> String

Remove `<thinking>...</thinking>` reasoning blocks (thinking models like
lfm2.5-thinking emit them before the answer). An unbalanced trailing
`<thinking>...` (still open at end) is dropped as well.
"""
function stripThinking(text::AbstractString)
    s = String(text)
    s = replace(s, r"<thinking>.*?</thinking>"s => "")
    s = replace(s, r"<thinking>.*$"s => "")
    return strip(s)
end
|
"""
    extractThinking(text) -> String

Return the raw content of the FIRST `<thinking>...</thinking>` reasoning
block in `text`, or "" when none is present. Unlike `stripThinking` (which
discards the block), this captures it for display — so the side panel can
show what the model reasoned before acting.
"""
function extractThinking(text::AbstractString)
    s = String(text)
    m = match(r"<thinking>(.*?)</thinking>"s, s)
    return m === nothing ? "" : String(m.captures[1])
end
|
"""
    ollamaReachable(; baseUrl, timeoutS = 2.0) :: Bool

Probe the inference server's root endpoint. Cheap gate so
probes/scripts can degrade gracefully when the server is down.
"""
function ollamaReachable(; baseUrl::AbstractString = defaultAgentModelConfig().baseUrl,
                         apiKey::AbstractString = "",
                         timeoutS::Real = 2.0)
    root = rtrimSlash(baseUrl)
    headers = ["Content-Type" => "application/json"]
    if !isempty(apiKey)
        push!(headers, "Authorization" => "Bearer " * String(apiKey))
    end
    try
        resp = HTTP.get(root * "/models", headers;
                        readtimeout = Int(timeoutS * 1000),
                        retry = false)
        return resp.status == 200
    catch
        return false
    end
end
|
"""
    streamCompletion(baseUrl, model, messages; onThinking = nothing, …) :: String

STREAMING chat round-trip (OpenAI-compatible SSE). Thinking arrives chunk by
chunk while the model is still generating: `onThinking(text)` is called for every
reasoning delta in arrival order, so the UI shows the monologue live instead of
one big block at the end. Returns the SAME folded string `chatCompletion`
returns (`withReasoning(content, reasoning)`), so the loop is unchanged.

Transport notes: `HTTP.open` keeps the body streaming; `data: [DONE]` ends it; a
body that is not SSE (some proxies ignore `stream`) is answered by the one-shot
path, so streaming degrades instead of failing.
"""
# A streaming reply that stops sending bytes is DEAD: without a per-read timeout
# `readline`/`readavailable` block forever and the run hangs with no status, no
# error and a stale "running" tool (observed: after typing into micro, the next
# completion stalled and the app sat there). 45 s of total silence is far beyond a
# reasoning model's longest pause, and bytes arriving keep the stream alive.
const STREAM_READ_TIMEOUT_S = 45.0

function streamCompletion(baseUrl::AbstractString, model::AbstractString,
                          messages::Vector{OllamaMessage};
                          temperature::Real = 0.2, apiKey::AbstractString = "",
                          timeoutS::Real = 120.0,
                          streamTimeoutS::Real = STREAM_READ_TIMEOUT_S,
                          reasoningField::AbstractString = DEFAULT_REASONING_FIELD,
                          maxTokens::Integer = 4096,
                          jsonMode::Bool = false,
                          onThinking = nothing)::String
    url = rtrimSlash(baseUrl) * "/chat/completions"
    bodyDict = Dict{String,Any}(
        "model" => String(model),
        "messages" => requestMessages(messages; reasoningField = reasoningField),
        "temperature" => Float64(temperature),
        "max_tokens" => Int(maxTokens),
        "stream" => true,
    )
    jsonMode && (bodyDict["response_format"] = Dict("type" => "json_object"))
    body = JSON3.write(bodyDict)
    headers = ["Content-Type" => "application/json", "Accept" => "text/event-stream"]
    isempty(apiKey) || push!(headers, "Authorization" => "Bearer " * String(apiKey))
    # NATIVE OLLAMA FIRST: its /api/chat streams `message.thinking` deltas and its
    # transport is FlootyStreams' (one `readavailable` frame at a time — the same
    # code path FlootyTUI/FlootyApp use), and it speaks `OllamaMessage` directly.
    # For any other OpenAI-compatible endpoint the SSE path below is used.
    root = replace(rtrimSlash(baseUrl), r"/v1$" => "")
    @debug "streamCompletion path" jsonMode = jsonMode native = (occursin(r":11434\b", root) && !jsonMode) model = model
    if occursin(r":11434\b", root) && !jsonMode
        try
            provider = FlootyStreams.OllamaProvider(baseURL = root,
                                                    timeout = Int(round(streamTimeoutS)))
            # FlootyStreams.chat takes format/options POSITIONALLY; keyword
            # arguments silently fell back to the SSE path (no format control).
            channel = FlootyStreams.chat(provider, messages, model, true,
                                         jsonMode ? "json" : nothing,
                                         Dict{String,Any}("num_predict" => Int(maxTokens)))
            nativeContent = IOBuffer()
            nativeThink = IOBuffer()
            for resp in channel
                # FlootyStreams.ChatResponse is a struct, not a dict: the old
                # get(resp, :message) always threw and silently forced every
                # completion onto the SSE fallback (so format=json never reached
                # the model).
                msg = resp.message
                t = msg.thinking
                if t !== nothing && !isempty(t)
                    print(nativeThink, t)
                    onThinking === nothing || onThinking(String(t))
                end
                c = msg.content
                (c === nothing || isempty(c)) || print(nativeContent, c)
                resp.done && break
            end
            return withReasoning(String(take!(nativeContent)),
                                 String(take!(nativeThink)))
        catch err
            @debug "native ollama streaming failed; using the SSE path" exception = err
        end
    end
    # OpenAI-compatible SSE path (used for any non-Ollama endpoint).
    content = IOBuffer()
    reasoning = IOBuffer()
    saw_sse = false
    # DEADLINE ENFORCED HERE: `readtimeout` on HTTP.open is NOT applied to streamed
    # reads (measured: a stalled peer blocked ~33 s regardless). A watchdog measures
    # SILENCE (time since the last data line, so a slow but live stream is fine) and
    # CLOSES the socket, which unblocks the read and fails the run instead of
    # hanging it forever.
    lastFrameAt = Ref(time())
    stalled = Ref(false)
    finished = Ref(false)
    ioRef = Ref{Any}(nothing)
    watchdog = @async begin
        while !finished[]
            sleep(0.25)
            finished[] && break
            if time() - lastFrameAt[] > Float64(streamTimeoutS)
                stalled[] = true
                try close(ioRef[]) catch end
                break
            end
        end
    end
    try
        HTTP.open("POST", url; headers = headers) do io
            ioRef[] = io
            write(io, body)
            closewrite(io)
            startread(io)
            # HTTP.Stream falls back to one-byte reads for readline/eof, which
            # floods the log and is slow. A buffered view fixes both without
            # changing the streaming contract.
            buffered = BufferedInputStream(io)
            saw_sse = consumeSSEFrames(buffered, onThinking;
                                       reasoningField = reasoningField,
                                       content = content, reasoning = reasoning,
                                       onFrame = () -> (lastFrameAt[] = time()))
        end
        stalled[] && error("stream stalled: no data for " *
                           "$(round(streamTimeoutS; digits = 1))s " *
                           "(model/endpoint stopped sending)")
    catch err
        stalled[] && error("stream stalled: no data for " *
                           "$(round(streamTimeoutS; digits = 1))s " *
                           "(model/endpoint stopped sending)")
        rethrow()
    finally
        finished[] = true
        try close(ioRef[]) catch end
    end
    full = String(take!(content))
    think = String(take!(reasoning))
    if !saw_sse
        return chatCompletion(baseUrl, model, messages; temperature = temperature,
                              apiKey = apiKey, timeoutS = timeoutS,
                              reasoningField = reasoningField,
                              maxTokens = maxTokens, jsonMode = jsonMode)
    end
    return withReasoning(full, think)
end

"""
    consumeSSEFrames(io, onThinking; reasoningField, content, reasoning) :: Bool

Read one OpenAI-compatible SSE body. Reasoning deltas go to `onThinking` (and to
`reasoning`), content deltas to `content`; returns whether any SSE frame was seen
(false means the peer ignored `stream` and answered with one plain JSON body, so
the caller falls back to the one-shot path). Pure I/O — unit-testable.
"""
function consumeSSEFrames(io::IO, onThinking;
                          reasoningField::AbstractString = DEFAULT_REASONING_FIELD,
                          content::IOBuffer = IOBuffer(),
                          reasoning::IOBuffer = IOBuffer(),
                          onFrame = nothing)::Bool
    saw = false
    while !eof(io)
        line = String(readline(io))
        onFrame === nothing || onFrame()
        startswith(line, "data:") || continue
        payload = strip(line[6:end])
        isempty(payload) && continue
        payload == "[DONE]" && break
        obj = try
            JSON3.read(payload)
        catch err
            continue
        end
        saw = true
        choices = get(obj, :choices, nothing)
        (choices === nothing || isempty(choices)) && continue
        delta = get(choices[1], :delta, nothing)
        delta === nothing && continue
        # Field order = preference; DEDUPED, or `reasoning` would count twice when
        # `reasoningField` is its default.
        think = ""
        fields = Symbol[]
        isempty(reasoningField) || push!(fields, Symbol(reasoningField))
        for f in (:reasoning, :reasoning_content, :thinking)
            f in fields || push!(fields, f)
        end
        for field in fields
            v = get(delta, field, nothing)
            (v === nothing || !(v isa AbstractString) || isempty(v)) && continue
            think *= String(v)
        end
        if !isempty(think)
            print(reasoning, think)
            onThinking === nothing || onThinking(think)
        end
        c = get(delta, :content, nothing)
        (c === nothing || !(c isa AbstractString)) && continue
        print(content, String(c))
    end
    return saw
end

"""
    makeCompleteFn(cfg, model; temperature, timeoutS, onThinking = nothing,
                   stream = true)

Build a `completeFn(messages)::String` bound to one configured model — the
default backend handed to the agent loop / monitor. With `stream` (default) the
reply is read as it is generated and `onThinking(chunk)` receives every reasoning
delta; any streaming failure falls back to the one-shot call, so a provider that
cannot stream still answers.
"""
makeCompleteFn(cfg::AgentModelConfig, model::AbstractString;
               temperature::Real = 0.2, timeoutS::Real = 120.0,
               maxTokens::Integer = cfg.maxOutputTokens,
               jsonMode::Bool = false,
               onThinking = nothing, stream::Bool = true) =
    messages -> begin
        selected = subscriptionModel(model)
        if selected !== nothing
            # shortcut: subscription replies are buffered; stream adapters when live thinking is required.
            return subscriptionComplete(subscriptionKind(selected.provider),
                subscriptionCredential(selected.provider), selected.model, messages;
                temperature = temperature, maxTokens = maxTokens, onThinking = onThinking,
                jsonMode = jsonMode, timeoutS = timeoutS)
        end
        if stream
            try
                return streamCompletion(cfg.baseUrl, model, messages;
                                        temperature = temperature, apiKey = cfg.apiKey,
                                        timeoutS = timeoutS,
                                        reasoningField = cfg.reasoningField,
                                        maxTokens = maxTokens,
                                        jsonMode = jsonMode,
                                        onThinking = onThinking)
            catch err
                @debug "streamCompletion failed; falling back to one-shot" exception = err
            end
        end
        return chatCompletion(cfg.baseUrl, model, messages;
                              temperature = temperature, apiKey = cfg.apiKey,
                              timeoutS = timeoutS,
                              reasoningField = cfg.reasoningField,
                              maxTokens = maxTokens, jsonMode = jsonMode)
    end

actorCompleteFn(cfg::AgentModelConfig = defaultAgentModelConfig();
                kwargs...) = makeCompleteFn(cfg, cfg.actorModel; jsonMode = true, kwargs...)
monitorCompleteFn(cfg::AgentModelConfig = defaultAgentModelConfig();
                  kwargs...) = makeCompleteFn(cfg, cfg.monitorModel; jsonMode = true, kwargs...)
