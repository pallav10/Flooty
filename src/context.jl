# context.jl — the model's context window: how big it is, how full we are, and
# how to compact before it overflows.
#
# Two facts drive this file:
#   * the window size belongs to the MODEL, not to us: Ollama-compatible
#     endpoints report it in `/api/show` as `model_info.<arch>.context_length`
#     (measured: beam:cloud = 1 048 576), and `/v1/models` sometimes carries it
#     per entry. `FLOOTY_CONTEXT_LENGTH` overrides everything.
#   * the payload grows every turn (snapshots + tool results). We track an
#     ESTIMATE (chars/4, the usual rough ratio for code+prose), log it, and
#     compact deterministically when it crosses the threshold — no extra model
#     call, so compaction can never fail or cost a turn.

const CONTEXT_LENGTH_CACHE = Dict{String,Int}()
const CONTEXT_LENGTH_LOCK = ReentrantLock()
const DEFAULT_CONTEXT_LENGTH = 32_768      # when nothing reports a window
const CONTEXT_COMPACT_AT = 0.85            # auto-compact at 85% of the window
const CONTEXT_KEEP_LAST = 24               # messages kept verbatim by compaction

"""
    contextLengthFor(model; baseUrl = defaultAgentModelConfig().baseUrl) :: Int

The model's context window in tokens. Order: `FLOOTY_CONTEXT_LENGTH` →
cached → the endpoint's own report (`/api/show` `model_info.*.context_length`,
then `/v1/models` entries) → `DEFAULT_CONTEXT_LENGTH`. Cached per model+endpoint.
"""
function contextLengthFor(model::AbstractString;
                          baseUrl::AbstractString = AGENT_CONFIG[].baseUrl)::Int
    key = String(model) * "@" * String(baseUrl)
    override = tryparse(Int, get(ENV, "FLOOTY_CONTEXT_LENGTH", ""))
    override !== nothing && override > 0 && return override
    subscriptionModel(model) === nothing || return DEFAULT_CONTEXT_LENGTH
    lock(CONTEXT_LENGTH_LOCK) do
        get(CONTEXT_LENGTH_CACHE, key, 0)
    end > 0 && return lock(CONTEXT_LENGTH_LOCK) do
        CONTEXT_LENGTH_CACHE[key]
    end

    found = _queryContextLength(String(model), String(baseUrl))
    limit = found > 0 ? found : DEFAULT_CONTEXT_LENGTH
    lock(CONTEXT_LENGTH_LOCK) do
        CONTEXT_LENGTH_CACHE[key] = limit
    end
    return limit
end

"Ask the endpoint (Ollama native first, OpenAI list second). 0 when unknown."
function _queryContextLength(model::String, baseUrl::String)::Int
    root = replace(rstrip(baseUrl, '/'), r"/v1$" => "")
    # 1. Ollama native: POST /api/show
    try
        resp = HTTP.post(root * "/api/show", ["Content-Type" => "application/json"],
                         JSON3.write(Dict("model" => model));
                         readtimeout = 8000, retry = false)
        body = String(resp.body)
        # `model_info` carries one `<arch>.context_length` (e.g. beam.context_length)
        for m in eachmatch(r"\"([a-zA-Z0-9_.-]*context_length)\"\s*:\s*(\d+)", body)
            n = parse(Int, m.captures[2])
            n > 0 && return n
        end
    catch err
        @debug "context: /api/show failed" exception = err
    end
    # 2. OpenAI-compatible list, when it carries per-model metadata
    try
        resp = HTTP.get(root * "/v1/models"; readtimeout = 8000, retry = false)
        body = String(resp.body)
        for entry in eachmatch(r"\{[^{}]*\}", body)
            occursin("\"" * model * "\"", entry.match) || continue
            m = match(r"\"(?:context_length|context_window|max_context_length)\"\s*:\s*(\d+)",
                      entry.match)
            m === nothing || return parse(Int, m.captures[1])
        end
    catch err
        @debug "context: /v1/models failed" exception = err
    end
    return 0
end

"Rough token estimate for a message list (chars/4 over role+content+reasoning)."
function estimateTokens(messages)::Int
    chars = 0
    for m in messages
        chars += length(something(m.content, "")) + length(something(m.thinking, ""))
        if m.tool_calls !== nothing
            for call in m.tool_calls
                chars += length(call.function_.name) + 16
            end
        end
    end
    return cld(chars, 4)
end

"Characters carried by a message list (what the estimate is derived from)."
function payloadChars(messages)::Int
    chars = 0
    for m in messages
        chars += length(something(m.content, "")) + length(something(m.thinking, ""))
    end
    return chars
end

"""
    contextUsage(messages; limit) -> (tokens, chars, limit, ratio)

One turn's context footprint: estimated tokens, raw characters, the model's
window, and the fill ratio (0…1).
"""
function contextUsage(messages; limit::Integer)
    chars = payloadChars(messages)
    tokens = cld(chars, 4)
    lim = Int(limit)
    return (tokens = tokens, chars = chars, limit = lim,
            ratio = lim > 0 ? min(1.0, tokens / lim) : 0.0)
end

"`12.3k` / `850` — short, for status lines."
function formatTokens(n::Integer)::String
    n >= 1000 ? string(round(n / 1000; digits = 1), "k") : string(n)
end

"""
    compactMessages!(messages; keepLast = CONTEXT_KEEP_LAST) -> (removed, kept)

Deterministic compaction: keep the SYSTEM prompt (first message) and the last
`keepLast` messages verbatim, fold everything between into ONE digest message
listing what was dropped. No model call, so it cannot fail and costs no turn.
Returns how many messages were removed and remain.
"""
function compactMessages!(messages::Vector{OllamaMessage};
                          keepLast::Integer = CONTEXT_KEEP_LAST)
    n = length(messages)
    keepLast = max(2, Int(keepLast))
    # system + digest + keepLast must fit, or there is nothing worth doing
    n <= keepLast + 2 && return (0, n)
    first_kept = n - keepLast + 1
    dropped = messages[2:(first_kept - 1)]
    roles = Dict{String,Int}()
    for m in dropped
        roles[m.role] = get(roles, m.role, 0) + 1
    end
    calls = sum(m -> m.tool_calls === nothing ? 0 : length(m.tool_calls), dropped;
                init = 0)
    # Carry the OBJECTIVE forward and turn what happened into milestones with
    # their latest status. This is deliberately deterministic (no summary model
    # call) so compaction can never fail or consume a turn.
    objective = ""
    milestones = String[]
    pending = nothing
    last_status = ""
    for m in dropped
        txt = strip(something(m.content, ""))
        isempty(txt) && continue
        if m.role == "user" && (startswith(txt, "TASK:") ||
                                startswith(txt, "STEER:") ||
                                startswith(txt, "USER INTERJECTION:"))
            objective = first(txt, 500)
            continue
        end
        if m.role == "assistant" && startswith(txt, "{")
            action = try JSON3.read(txt) catch; nothing end
            action isa AbstractDict || continue
            kind = string(get(action, "action", ""))
            if kind == "send"
                pending = "send: " * first(string(get(action, "code", "")), 220)
            elseif kind == "type"
                pending = "type: " * first(string(get(action, "keys", "")), 120)
            elseif kind == "done"
                summary = first(string(get(action, "summary", "")), 260)
                isempty(summary) || push!(milestones, "- [done] " * summary)
                last_status = "done"
            elseif kind in ("newTerminal", "splitTerminal", "newChat", "closeSplit",
                            "compact", "feedback", "interrupt")
                push!(milestones, "- [done] " * kind * ": " *
                                  first(string(get(action, "reason", get(action, "title", ""))), 160))
            end
            length(milestones) > 24 && popfirst!(milestones)
            continue
        end
        if m.role == "user" && pending !== nothing &&
           startswith(txt, "ACTION RESULT:")
            firstline = strip(first(split(txt, '\n')))
            status = occursin("ERROR", uppercase(firstline)) ? "error" :
                     occursin("STARTED", uppercase(firstline)) ? "running" : "ok"
            push!(milestones, "- [" * status * "] ran: " * pending)
            last_status = status
            pending = nothing
            length(milestones) > 24 && popfirst!(milestones)
        end
    end
    pending !== nothing && push!(milestones, "- [open] ran: " * pending)
    head = "[compacted] " * string(length(dropped)) * " earlier messages were " *
           "summarised away to save context (" *
           join(["$(r)=$(c)" for (r, c) in sort(collect(roles))], ", ") *
           (calls > 0 ? ", tool_calls=$calls" : "") * ")."
    body = "\nOBJECTIVE: " * (isempty(objective) ? "(not captured)" : objective)
    body *= "\nMILESTONES:\n" *
            (isempty(milestones) ? "- (none recorded)" : join(milestones, "\n"))
    body *= "\nCURRENT STATUS: " *
            (isempty(last_status) ? "no completed action" : last_status)
    body *= "\nNEXT STEP: " *
            (pending === nothing ?
             "continue from the terminal snapshot; verify the last result before acting." :
             "finish or verify the open command above.")
    digest = OllamaMessage(role = "user",
        content = head * body * "\nRecent messages below are kept verbatim; the " *
                  "terminal snapshot is the current screen.")
    kept = vcat(messages[1:1], [digest], messages[first_kept:end])
    empty!(messages)
    append!(messages, kept)
    return (length(dropped), length(messages))
end
