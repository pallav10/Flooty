# GitHub device OAuth and Copilot wire protocol; see OMP registry/oauth/github-copilot.ts
# and catalog/src/wire/github-copilot.ts. Current Copilot accepts the GitHub grant directly.
const COPILOT_PUBLIC_CLIENT = "Ov23li8tweQw6odWQebz"
const COPILOT_ENTERPRISE_CLIENT = "Ov23ctDVkRmgkPke0Mmm"
const COPILOT_OAUTH_HEADERS = ["Accept" => "application/json",
    "Content-Type" => "application/x-www-form-urlencoded",
    "User-Agent" => "copilot-developer-action/0.0.1"]
const COPILOT_PUBLIC_BASES = ("https://api.githubcopilot.com",
    "https://api.individual.githubcopilot.com", "https://api.business.githubcopilot.com",
    "https://api.enterprise.githubcopilot.com")

function normalizeCopilotDomain(value::AbstractString)::String
    input = lowercase(strip(value))
    isempty(input) && return "github.com"
    parsed = match(r"^(?:https://)?([a-z0-9.-]+)(?::443)?/?$", input)
    parsed === nothing && throw(ArgumentError("Enter a GitHub DNS hostname or HTTPS root URL."))
    domain = String(parsed.captures[1])
    labels = split(domain, '.')
    length(domain) <= 253 && length(labels) >= 2 &&
        all(label -> occursin(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", label), labels) &&
        occursin(r"[a-z]", labels[end]) &&
        !all(label -> occursin(r"^(?:[0-9]+|0x[0-9a-f]+)$", label), labels) &&
        !endswith(domain, ".localhost") ||
        throw(ArgumentError("Enter a valid non-local GitHub DNS hostname."))
    return domain in ("github.com", "www.github.com", "api.github.com") ? "github.com" : domain
end

copilotClient(domain::String) = domain == "github.com" ? COPILOT_PUBLIC_CLIENT : COPILOT_ENTERPRISE_CLIENT
copilotDefaultBase(domain::String) = domain == "github.com" ? first(COPILOT_PUBLIC_BASES) :
    "https://" * (startswith(domain, "copilot-api.") ? domain : "copilot-api." * domain)

function copilotText(value, label::AbstractString)::String
    value isa AbstractString && !isempty(strip(value)) && !any(iscntrl, value) ||
        error("GitHub Copilot returned invalid " * label)
    return String(value)
end

function copilotPositive(value, label::AbstractString)::Float64
    value isa Real && !(value isa Bool) && isfinite(value) && value > 0 ||
        error("GitHub Copilot returned invalid " * label)
    return Float64(value)
end

function copilotBase(value, domain::AbstractString="github.com")::String
    host = normalizeCopilotDomain(domain)
    value isa AbstractString || error("Untrusted GitHub Copilot endpoint")
    base = endswith(value, "/") ? String(chop(value)) : String(value)
    trusted = host == "github.com" ? base in COPILOT_PUBLIC_BASES : base == copilotDefaultBase(host)
    trusted || error("Untrusted GitHub Copilot endpoint")
    return base
end

function copilotBase(credential::AbstractDict)::String
    domain = normalizeCopilotDomain(get(credential, "githubDomain", "github.com"))
    return copilotBase(get(credential, "apiEndpoint", copilotDefaultBase(domain)), domain)
end

function copilotHeaders(access; discovery::Bool=false, anthropic::Bool=false)
    token = copilotText(access, "credential")
    headers = ["Authorization" => "Bearer " * token, "Accept" => "application/json",
        "Content-Type" => "application/json", "User-Agent" => "copilot/1.0.82",
        "Editor-Version" => "copilot/1.0.82", "Copilot-Harness-Id" => "copilot-sdk",
        "Copilot-Integration-Id" => (discovery ? "copilot-developer-cli" : "copilot-chat"),
        "Openai-Intent" => "conversation-agent", "X-GitHub-Api-Version" => "2026-08-01",
        "X-Initiator" => "user"]
    discovery || push!(headers, "X-Interaction-Type" => "conversation-user")
    if anthropic
        push!(headers, "anthropic-version" => "2023-06-01",
            "Anthropic-Dangerous-Direct-Browser-Access" => "true")
    end
    return headers
end

function copilotAccountBase(access, domain::String="github.com")::String
    token = copilotText(access, "credential")
    domain == "github.com" || return copilotDefaultBase(domain)
    profile = subscriptionJson(subscriptionRequest("GET",
        "https://api.github.com/copilot_internal/user",
        ["Accept" => "application/json", "Authorization" => "token " * token,
            "User-Agent" => "copilot/1.0.82"]))
    haskey(profile, "error") && error("GitHub Copilot account authorization failed")
    endpoints = get(profile, "endpoints", nothing)
    endpoints === nothing && return first(COPILOT_PUBLIC_BASES)
    endpoints isa AbstractDict || error("GitHub Copilot returned invalid endpoints")
    return copilotBase(get(endpoints, "api", first(COPILOT_PUBLIC_BASES)), domain)
end

function copilotCredential(payload::AbstractDict; previousRefresh::String="", domain::String="github.com")::Dict{String,Any}
    domain = normalizeCopilotDomain(domain)
    haskey(payload, "error") && error("GitHub Copilot token exchange failed; sign in again")
    haskey(payload, "apiEndpoint") && copilotBase(payload["apiEndpoint"], domain)
    endpoints = get(payload, "endpoints", Dict{String,Any}())
    endpoints isa AbstractDict || error("GitHub Copilot returned invalid endpoints")
    haskey(endpoints, "api") && copilotBase(endpoints["api"], domain)
    access = copilotText(get(payload, "access_token", nothing), "access token")
    tokenType = get(payload, "token_type", "bearer")
    tokenType isa AbstractString && lowercase(tokenType) == "bearer" ||
        error("GitHub Copilot returned unsupported token type")
    refresh = get(payload, "refresh_token", previousRefresh)
    refresh isa AbstractString || error("GitHub Copilot returned invalid refresh token")
    isempty(refresh) || copilotText(refresh, "refresh token")
    expiry = haskey(payload, "expires_in") ? time() + copilotPositive(payload["expires_in"], "token lifetime") : 0.0
    expiry > 0 && isempty(refresh) && error("GitHub Copilot expiring grant has no refresh token")
    return Dict{String,Any}("access" => access, "refresh" => String(refresh),
        "expiresAt" => expiry, "githubDomain" => domain, "apiEndpoint" => copilotAccountBase(access, domain))
end

function loginSubscription!(::Val{:github_copilot}, attempt::SubscriptionLogin)::Dict{String,Any}
    checkSubscriptionLogin(attempt)
    domain = normalizeCopilotDomain(attempt.domain)
    client = copilotClient(domain)
    origin = "https://" * domain
    device = subscriptionJson(subscriptionRequest("POST", origin * "/login/device/code",
        COPILOT_OAUTH_HEADERS, subscriptionForm(Dict("client_id" => client,
            "scope" => "read:user"))))
    deviceCode = copilotText(get(device, "device_code", nothing), "device code")
    userCode = copilotText(get(device, "user_code", nothing), "user code")
    verification = get(device, "verification_uri", nothing)
    verification == origin * "/login/device" || error("Untrusted GitHub device verification URL")
    interval = copilotPositive(get(device, "interval", 5), "poll interval")
    expiry = time() + copilotPositive(get(device, "expires_in", nothing), "device lifetime")
    checkSubscriptionLogin(attempt)
    updateSubscriptionLogin!(attempt; kind="device", authorizationUrl=verification,
        userCode=userCode, instructions="Open GitHub and enter the displayed code to authorize Copilot.",
        expiresAt=expiry)
    multiplier = 1.2
    while true
        checkSubscriptionLogin(attempt)
        subscriptionSleep(attempt, min(interval * multiplier, max(0.0, attempt.expiresAt - time())))
        checkSubscriptionLogin(attempt)
        response = subscriptionRequest("POST", origin * "/login/oauth/access_token",
            COPILOT_OAUTH_HEADERS, subscriptionForm(Dict("client_id" => client,
                "device_code" => deviceCode, "grant_type" => "urn:ietf:params:oauth:grant-type:device_code")))
        payload = subscriptionJson(response; statuses=(200, 400))
        checkSubscriptionLogin(attempt)
        state = get(payload, "error", nothing)
        if state == "authorization_pending"
            continue
        elseif state == "slow_down"
            advertised = get(payload, "interval", nothing)
            interval = advertised === nothing ? interval + 5 :
                max(interval + 5, copilotPositive(advertised, "poll interval"))
            multiplier = 1.4
            continue
        elseif state !== nothing
            message = state == "access_denied" ? "GitHub device authorization was denied" :
                state == "expired_token" ? "GitHub device authorization expired; sign in again" :
                "GitHub device authorization failed; sign in again"
            error(message)
        end
        response.status == 200 || error("GitHub device token exchange failed")
        credential = copilotCredential(payload; domain=domain)
        checkSubscriptionLogin(attempt)
        return credential
    end
end

function refreshSubscriptionCredential(::Val{:github_copilot}, credential::Dict{String,Any})::Dict{String,Any}
    # GitHub public OAuth grants normally have no expiry or refresh token. Revalidate rather than inventing renewal.
    domain = normalizeCopilotDomain(get(credential, "githubDomain", "github.com"))
    copilotBase(credential)
    refresh = get(credential, "refresh", "")
    if refresh isa AbstractString && !isempty(refresh)
        token = copilotText(refresh, "refresh token")
        payload = subscriptionJson(subscriptionRequest("POST", "https://" * domain * "/login/oauth/access_token",
            COPILOT_OAUTH_HEADERS, subscriptionForm(Dict("client_id" => copilotClient(domain),
                "grant_type" => "refresh_token", "refresh_token" => token))))
        return copilotCredential(payload; previousRefresh=token, domain=domain)
    end
    get(credential, "expiresAt", 0) == 0 || error("GitHub Copilot grant expired; sign in again")
    updated = copy(credential)
    updated["githubDomain"] = domain
    updated["apiEndpoint"] = copilotAccountBase(get(credential, "access", nothing), domain)
    return updated
end

function copilotModels(credential::Dict{String,Any})
    base = copilotBase(credential)
    catalog = subscriptionJson(subscriptionRequest("GET", base * "/models",
        copilotHeaders(get(credential, "access", nothing); discovery=true)))
    haskey(catalog, "error") && error("GitHub Copilot model discovery failed")
    rows = get(catalog, "data", nothing)
    rows isa AbstractVector || error("GitHub Copilot returned invalid model catalog")
    found = Dict{String,Any}[]
    for row in rows
        row isa AbstractDict || error("GitHub Copilot returned invalid model")
        caps = get(row, "capabilities", nothing)
        caps === nothing || caps isa AbstractDict || error("GitHub Copilot returned invalid capabilities")
        caps isa AbstractDict && haskey(caps, "type") && caps["type"] != "chat" && continue
        copilotText(get(row, "id", nothing), "model identifier")
        push!(found, Dict{String,Any}(row))
    end
    return found
end

function subscriptionModelList(::Val{:github_copilot}, credential::Dict{String,Any})::Vector{String}
    return sort!(unique(String[row["id"] for row in copilotModels(credential)]))
end

function copilotRoute(row::AbstractDict)::String
    endpoints = get(row, "supported_endpoints", nothing)
    if endpoints === nothing
        # Current OMP compat/rules/behavior.kdl:216-219; FlowOps shared/llm.py:383-401.
        id = copilotText(get(row, "id", nothing), "model identifier")
        any(prefix -> startswith(id, prefix), ("claude-haiku-", "claude-sonnet-", "claude-opus-",
            "claude-fable-", "claude-mythos-")) && return "messages"
        any(prefix -> startswith(id, prefix), ("grok-4.", "gpt-5", "gpt-6", "oswe", "mai-")) && return "responses"
        return "chat"
    end
    endpoints isa AbstractVector || error("GitHub Copilot returned invalid model endpoints")
    for (names, route) in (( ("/v1/messages", "/messages", "messages"), "messages"),
            (("/responses", "responses"), "responses"),
            (("/chat/completions", "chat/completions", "chat.completions"), "chat"))
        any(endpoint -> endpoint in names, endpoints) && return route
    end
    error("GitHub Copilot model has no supported conversational endpoint")
end

function copilotMessages(messages::Vector{OllamaMessage}; anthropic::Bool=false)
    wire = Dict{String,Any}[]
    systems = String[]
    for message in messages
        role = String(message.role)
        role in ("system", "user", "assistant") || error("Unsupported GitHub Copilot message role")
        content = message.content === nothing ? "" : String(message.content)
        anthropic && isempty(content) && continue
        if anthropic && role == "system"
            push!(systems, content)
        elseif anthropic && !isempty(wire) && wire[end]["role"] == role
            wire[end]["content"] *= "\n\n" * content
        else
            push!(wire, Dict{String,Any}("role" => role, "content" => content))
        end
    end
    isempty(wire) && error("GitHub Copilot completion needs conversation messages")
    return wire, join(systems, "\n\n")
end

function copilotEvents(response::HTTP.Response)
    response.status == 200 || error("GitHub Copilot completion failed (HTTP $(response.status))")
    text = String(response.body)
    events = Dict{String,Any}[]
    for block in split(replace(text, "\r\n" => "\n"), "\n\n")
        data = join([length(line) > 5 ? lstrip(line[6:end]) : "" for line in split(block, '\n')
            if startswith(line, "data:")], "\n")
        isempty(data) && continue
        data == "[DONE]" && continue
        event = try JSON3.read(data, Dict{String,Any}) catch; error("GitHub Copilot returned invalid stream data") end
        event isa AbstractDict || error("GitHub Copilot returned invalid stream event")
        push!(events, event)
    end
    isempty(events) && error("GitHub Copilot returned an empty or invalid event stream")
    return events
end

function copilotDeltaText(value)::String
    value === nothing && return ""
    value isa AbstractString && return String(value)
    value isa AbstractVector || error("GitHub Copilot returned invalid content delta")
    parts = String[]
    for block in value
        text = block isa AbstractString ? block : block isa AbstractDict ? get(block, "text", "") : nothing
        text isa AbstractString || error("GitHub Copilot returned invalid content block")
        push!(parts, String(text))
    end
    return join(parts)
end

function copilotFold(events, route::String; onThinking=nothing)::String
    content = IOBuffer()
    reasoning = IOBuffer()
    finished = false
    stopAccepted = false
    for event in events
        eventType = get(event, "type", "")
        (get(event, "error", nothing) !== nothing || eventType in ("error", "response.failed", "response.incomplete")) &&
            error("GitHub Copilot completion stream failed")
        text = ""
        thought = ""
        if route == "chat"
            choices = get(event, "choices", Any[])
            choices isa AbstractVector || error("GitHub Copilot returned invalid choices")
            for choice in choices
                choice isa AbstractDict || error("GitHub Copilot returned invalid choice")
                get(choice, "index", 0) == 0 || continue
                delta = get(choice, "delta", Dict{String,Any}())
                delta isa AbstractDict || error("GitHub Copilot returned invalid completion delta")
                text = copilotDeltaText(get(delta, "content", nothing))
                thought = something(get(delta, "reasoning_content", get(delta, "reasoning", nothing)), "")
                finish = get(choice, "finish_reason", nothing)
                if finish !== nothing
                    finish == "stop" || error("GitHub Copilot completion was truncated, filtered, or unsupported")
                    finished = true
                end
            end
        elseif route == "messages"
            if eventType == "content_block_delta"
                delta = get(event, "delta", Dict{String,Any}())
                delta isa AbstractDict || error("GitHub Copilot returned invalid message delta")
                text = get(delta, "text", "")
                thought = get(delta, "thinking", "")
            elseif eventType == "message_delta"
                delta = get(event, "delta", Dict{String,Any}())
                delta isa AbstractDict || error("GitHub Copilot returned invalid message delta")
                get(delta, "stop_reason", nothing) in ("end_turn", "stop_sequence") ||
                    error("GitHub Copilot completion was truncated or unsupported")
                stopAccepted = true
            elseif eventType == "message_stop"
                stopAccepted || error("GitHub Copilot message stream ended without a stop reason")
                finished = true
            end
        else
            if eventType == "response.output_text.delta"
                text = get(event, "delta", "")
            elseif eventType in ("response.reasoning_summary_text.delta", "response.reasoning_text.delta")
                thought = get(event, "delta", "")
            elseif eventType == "response.completed"
                result = get(event, "response", Dict{String,Any}())
                result isa AbstractDict || error("GitHub Copilot returned invalid response completion")
                get(result, "status", nothing) == "completed" && get(result, "error", nothing) === nothing ||
                    error("GitHub Copilot response did not complete")
                finished = true
            elseif eventType == "response.refusal.delta"
                error("GitHub Copilot refused the completion")
            end
        end
        text isa AbstractString && thought isa AbstractString || error("GitHub Copilot returned invalid text")
        write(content, text)
        write(reasoning, thought)
        !isempty(thought) && onThinking !== nothing && onThinking(String(thought))
    end
    finished || error("GitHub Copilot completion stream ended prematurely")
    answer = String(take!(content))
    isempty(strip(answer)) && error("GitHub Copilot returned an empty completion")
    return withReasoning(answer, String(take!(reasoning)))
end

function copilotCompletionRequest(url::String, headers, payload; timeoutS::Real)
    response = subscriptionRequest("POST", url, headers, JSON3.write(payload); timeoutS=timeoutS)
    denied = response.status == 403
    if response.status == 400
        body = try JSON3.read(String(response.body), Dict{String,Any}) catch; Dict{String,Any}() end
        detail = get(body, "error", nothing)
        denied = detail isa AbstractDict && get(detail, "code", nothing) == "model_not_supported"
    end
    if denied
        # OMP github-copilot-headers.ts: some Business policies permit CLI but deny chat identity.
        retryHeaders = [name => (name == "Copilot-Integration-Id" ? "copilot-developer-cli" : value)
            for (name, value) in headers]
        return subscriptionRequest("POST", url, retryHeaders, JSON3.write(payload); timeoutS=timeoutS)
    end
    return response
end

function subscriptionComplete(::Val{:github_copilot}, credential::Dict{String,Any},
        model::AbstractString, messages::Vector{OllamaMessage}; temperature::Real=0.2,
        maxTokens::Integer=4096, onThinking=nothing, jsonMode::Bool=false,
        timeoutS::Real=120.0)::String
    maxTokens > 0 && isfinite(temperature) && isfinite(timeoutS) && timeoutS > 0 ||
        error("Invalid GitHub Copilot completion parameters")
    base = copilotBase(credential)
    rows = copilotModels(credential)
    selected = findfirst(row -> row["id"] == model, rows)
    selected === nothing && error("GitHub Copilot model is not available for this account")
    route = copilotRoute(rows[selected])
    wire, system = copilotMessages(messages; anthropic=route == "messages")
    payload = Dict{String,Any}("model" => String(model), "stream" => true)
    if route == "messages"
        payload["messages"] = wire
        isempty(system) || (payload["system"] = system)
        payload["max_tokens"] = maxTokens
        path = "/v1/messages"
    elseif route == "responses"
        payload["input"] = wire
        path = "/responses"
    else
        payload["messages"] = wire
        payload["stream_options"] = Dict("include_usage" => true)
        jsonMode && (payload["response_format"] = Dict("type" => "json_object"))
        path = "/chat/completions"
    end
    # Copilot chat/responses choose their own output and sampling limits (FlowOps _copilot.py).
    headers = copilotHeaders(get(credential, "access", nothing); anthropic=route == "messages")
    headers[2] = "Accept" => "text/event-stream"
    response = copilotCompletionRequest(base * path, headers, payload; timeoutS=timeoutS)
    return copilotFold(copilotEvents(response), route; onThinking=onThinking)
end
