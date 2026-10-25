# Subscription OAuth uses the Grok CLI proxy, never the API-key/billing endpoint.
# Wire reference: corbitsdev/corbits-xai-provider src/{constants,oauth,responses-adapter}.ts.
const XAI_SUBSCRIPTION_ISSUER = "https://auth.x.ai"
const XAI_SUBSCRIPTION_PROXY = "https://cli-chat-proxy.grok.com/v1"
const XAI_SUBSCRIPTION_CLIENT = "b1a00492-073a-47ea-816f-4c329264a828"
const XAI_SUBSCRIPTION_REDIRECT = "http://127.0.0.1:1456/callback"
const XAI_SUBSCRIPTION_SCOPES = "openid profile email offline_access grok-cli:access api:access"
const XAI_SUBSCRIPTION_VERSION = "1.0.62"

function xaiSubscriptionSecret(value, field::AbstractString)
    value isa AbstractString && !isempty(strip(value)) &&
        !any(c -> iscntrl(c), value) || error("xAI: invalid $field")
    return String(value)
end

function xaiSubscriptionEndpoint(value, field::AbstractString)
    value isa AbstractString || error("xAI: missing $field")
    uri = try HTTP.URI(String(value)) catch; error("xAI: invalid $field") end
    uri.scheme == "https" && lowercase(uri.host) == "auth.x.ai" &&
        uri.port in ("", "443") && isempty(uri.userinfo) && isempty(uri.fragment) &&
        isempty(uri.query) && startswith(uri.path, "/") &&
        !any(iscntrl, value) || error("xAI: untrusted $field")
    return String(value)
end

function xaiSubscriptionDetail(payload, secrets = String[])
    source = payload isa AbstractDict ? get(payload, "error", payload) : nothing
    fields = source isa AbstractDict ?
        [get(source, key, "") for key in ("type", "code", "message")] :
        [source, payload isa AbstractDict ? get(payload, "error_description", "") : ""]
    text = join([String(item) for item in fields if item isa AbstractString && !isempty(item)], ": ")
    for secret in secrets
        isempty(secret) || (text = replace(text, secret => "[redacted]"))
    end
    text = replace(text, r"(?i)bearer\s+\S+" => "Bearer [redacted]",
        r"https?://\S+" => "[URL redacted]",
        r"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+)?" => "[redacted]",
        r"[\x00-\x1f\x7f]" => " ")
    return first(text, 600)
end

function xaiSubscriptionJson(response; secrets = String[])
    payload = try JSON3.read(String(copy(response.body)), Dict{String,Any}) catch
        error("xAI: invalid JSON response (HTTP $(response.status))")
    end
    if response.status != 200 || haskey(payload, "error")
        detail = xaiSubscriptionDetail(payload, secrets)
        error("xAI: request rejected (HTTP $(response.status))" * (isempty(detail) ? "" : ": " * detail))
    end
    return payload
end

function xaiSubscriptionDiscovery()
    document = xaiSubscriptionJson(subscriptionRequest("GET",
        XAI_SUBSCRIPTION_ISSUER * "/.well-known/openid-configuration", ["Accept" => "application/json"]))
    get(document, "issuer", nothing) == XAI_SUBSCRIPTION_ISSUER || error("xAI: untrusted OAuth issuer")
    authorization = xaiSubscriptionEndpoint(get(document, "authorization_endpoint", nothing), "authorization endpoint")
    token = xaiSubscriptionEndpoint(get(document, "token_endpoint", nothing), "token endpoint")
    "S256" in get(document, "code_challenge_methods_supported", []) || error("xAI: OAuth server does not support S256 PKCE")
    return (; authorization, token)
end

function xaiSubscriptionClaims(access::AbstractString)
    pieces = split(access, '.')
    length(pieces) == 3 || return Dict{String,Any}()
    try
        encoded = replace(pieces[2], '-' => '+', '_' => '/')
        encoded *= repeat("=", mod(-ncodeunits(encoded), 4))
        return JSON3.read(String(base64decode(encoded)), Dict{String,Any})
    catch
        return Dict{String,Any}()
    end
end

function xaiSubscriptionTokens(payload::AbstractDict; previousRefresh::AbstractString = "")
    access = xaiSubscriptionSecret(get(payload, "access_token", nothing), "access token")
    lowercase(String(get(payload, "token_type", "Bearer"))) == "bearer" || error("xAI: unsupported OAuth token type")
    refresh = get(payload, "refresh_token", previousRefresh)
    refresh === nothing && (refresh = previousRefresh)
    refresh isa AbstractString || error("xAI: invalid refresh token")
    isempty(refresh) && (refresh = previousRefresh)
    isempty(refresh) || xaiSubscriptionSecret(refresh, "refresh token")
    claims = xaiSubscriptionClaims(access) # Identity metadata only; never an authorization decision.
    lifetime = get(payload, "expires_in", nothing)
    expiresAt = if lifetime isa Real && !(lifetime isa Bool) && isfinite(lifetime) && lifetime > 0
        time() + lifetime
    else
        get(claims, "exp", nothing)
    end
    expiresAt isa Real && !(expiresAt isa Bool) && isfinite(expiresAt) && expiresAt > time() ||
        error("xAI: token response has no valid expiry")
    accountId = get(claims, "sub", nothing)
    if !(accountId isa AbstractString) || isempty(accountId)
        identity = xaiSubscriptionJson(subscriptionRequest("GET", XAI_SUBSCRIPTION_ISSUER * "/oauth2/userinfo",
            ["Authorization" => "Bearer " * access, "Accept" => "application/json"]); secrets = [access, String(refresh)])
        accountId = get(identity, "sub", nothing)
    end
    accountId = xaiSubscriptionSecret(accountId, "account identity")
    return Dict{String,Any}("access" => access, "refresh" => String(refresh),
        "expiresAt" => Float64(expiresAt), "accountId" => accountId)
end

function loginSubscription!(::Val{:xai}, attempt::SubscriptionLogin)::Dict{String,Any}
    checkSubscriptionLogin(attempt)
    endpoints = xaiSubscriptionDiscovery()
    checkSubscriptionLogin(attempt)
    pkce = newSubscriptionPkce()
    query = subscriptionForm(Dict("client_id" => XAI_SUBSCRIPTION_CLIENT,
        "redirect_uri" => XAI_SUBSCRIPTION_REDIRECT, "response_type" => "code",
        "scope" => XAI_SUBSCRIPTION_SCOPES, "state" => pkce.state,
        "code_challenge" => pkce.challenge, "code_challenge_method" => "S256"))
    updateSubscriptionLogin!(attempt; kind = "paste", authorizationUrl = endpoints.authorization * "?" * query,
        instructions = "Sign in to a Grok account with CLI access, then paste the full redirected http://127.0.0.1:1456/callback URL, even if the browser cannot open it. Access and quotas depend on your Grok/X subscription or trial; this does not use xAI API-key billing.",
        expiresAt = min(attempt.expiresAt, time() + 600))
    input = waitSubscriptionInput!(attempt)
    checkSubscriptionLogin(attempt)
    code = subscriptionCallback(input, XAI_SUBSCRIPTION_REDIRECT, pkce.state)
    checkSubscriptionLogin(attempt)
    fields = Dict("grant_type" => "authorization_code", "client_id" => XAI_SUBSCRIPTION_CLIENT,
        "redirect_uri" => XAI_SUBSCRIPTION_REDIRECT, "code" => code, "code_verifier" => pkce.verifier)
    response = subscriptionRequest("POST", endpoints.token,
        ["Accept" => "application/json", "Content-Type" => "application/x-www-form-urlencoded"], subscriptionForm(fields))
    checkSubscriptionLogin(attempt)
    credential = xaiSubscriptionTokens(xaiSubscriptionJson(response; secrets = [code, pkce.verifier]))
    checkSubscriptionLogin(attempt)
    return credential
end

function refreshSubscriptionCredential(::Val{:xai}, credential::Dict{String,Any})::Dict{String,Any}
    refresh = xaiSubscriptionSecret(get(credential, "refresh", nothing), "refresh token; sign in again")
    endpoints = xaiSubscriptionDiscovery()
    response = subscriptionRequest("POST", endpoints.token,
        ["Accept" => "application/json", "Content-Type" => "application/x-www-form-urlencoded"],
        subscriptionForm(Dict("grant_type" => "refresh_token", "client_id" => XAI_SUBSCRIPTION_CLIENT,
            "refresh_token" => refresh)))
    return xaiSubscriptionTokens(xaiSubscriptionJson(response;
        secrets = [refresh, String(get(credential, "access", ""))]); previousRefresh = refresh)
end

function xaiSubscriptionHeaders(credential::Dict{String,Any}; model::AbstractString = "", stream::Bool = false)
    access = xaiSubscriptionSecret(get(credential, "access", nothing), "access token")
    accountId = xaiSubscriptionSecret(get(credential, "accountId", get(xaiSubscriptionClaims(access), "sub", nothing)), "account identity")
    headers = ["Authorization" => "Bearer " * access,
        "Accept" => (stream ? "text/event-stream" : "application/json"),
        "User-Agent" => "grok-shell/$(XAI_SUBSCRIPTION_VERSION) (macos; aarch64)",
        "x-grok-client-identifier" => "grok-shell", "x-grok-client-version" => XAI_SUBSCRIPTION_VERSION,
        "x-grok-client-mode" => "interactive", "x-xai-token-auth" => "xai-grok-cli",
        "x-authenticateresponse" => "authenticate-response", "x-grok-user-id" => accountId]
    isempty(model) || push!(headers, "x-grok-model-override" => xaiSubscriptionSecret(model, "model"))
    return headers
end

function subscriptionModelList(::Val{:xai}, credential::Dict{String,Any})::Vector{String}
    headers = xaiSubscriptionHeaders(credential)
    models = String[]
    cursors = Set{String}()
    after = ""
    while true
        url = XAI_SUBSCRIPTION_PROXY * "/models" * (isempty(after) ? "" : "?" * subscriptionForm(Dict("after" => after)))
        payload = xaiSubscriptionJson(subscriptionRequest("GET", url, headers);
            secrets = [String(credential["access"]), String(get(credential, "refresh", ""))])
        rows = get(payload, "data", nothing)
        rows isa AbstractVector || error("xAI: model response has no model list")
        for row in rows
            row isa AbstractDict || error("xAI: invalid model entry")
            id = xaiSubscriptionSecret(get(row, "id", nothing), "model ID")
            # Only discovered text models belong in Flooty's actor/monitor picker.
            any(prefix -> startswith(id, prefix), ("grok-imagine-", "grok-stt-", "grok-voice-", "grok-tts")) && continue
            id in models || push!(models, id)
        end
        get(payload, "has_more", false) === true || break
        next = get(payload, "last_id", isempty(rows) ? "" : get(last(rows), "id", ""))
        next = xaiSubscriptionSecret(next, "model pagination cursor")
        next in cursors && error("xAI: repeated model pagination cursor")
        push!(cursors, next)
        after = next
    end
    isempty(models) && error("xAI: account has no available text models; check Grok subscription entitlement")
    return models
end

function xaiSubscriptionOutput(response::AbstractDict)
    get(response, "status", "") == "completed" || error("xAI: completion did not finish successfully")
    output = get(response, "output", Any[])
    output isa AbstractVector || error("xAI: invalid completion output")
    content, reasoning = IOBuffer(), IOBuffer()
    for item in output
        item isa AbstractDict || continue
        kind = get(item, "type", "")
        if kind == "message"
            get(item, "status", "completed") == "completed" || error("xAI: incomplete assistant message")
            for part in get(item, "content", Any[])
                part isa AbstractDict || continue
                if get(part, "type", "") == "output_text"
                    print(content, get(part, "text", ""))
                elseif get(part, "type", "") == "refusal"
                    error("xAI: model refused the request")
                end
            end
        elseif kind == "reasoning"
            for part in get(item, "summary", Any[])
                part isa AbstractDict && print(reasoning, get(part, "text", ""))
            end
        end
    end
    return String(take!(content)), String(take!(reasoning))
end

function xaiSubscriptionCompletion(response, credential; onThinking = nothing)
    secrets = [String(credential["access"]), String(get(credential, "refresh", ""))]
    response.status == 200 || xaiSubscriptionJson(response; secrets)
    text = String(copy(response.body))
    if startswith(lstrip(text), "{")
        payload = xaiSubscriptionJson(response; secrets)
        content, reasoning = xaiSubscriptionOutput(payload)
        isempty(strip(content)) && error("xAI: completion contains no assistant text")
        onThinking === nothing || isempty(reasoning) || onThinking(reasoning)
        return withReasoning(content, reasoning)
    end
    content, reasoning = IOBuffer(), IOBuffer()
    completed = false
    terminalContent, terminalReasoning = "", ""
    for frame in split(replace(text, "\r\n" => "\n"), "\n\n")
        data = join([chopprefix(line, "data:") |> lstrip for line in split(frame, '\n') if startswith(line, "data:")], "\n")
        isempty(data) && continue
        data == "[DONE]" && continue
        event = try JSON3.read(data, Dict{String,Any}) catch; error("xAI: malformed completion event") end
        kind = get(event, "type", "")
        if kind in ("error", "response.failed", "response.incomplete")
            payload = get(event, "response", event)
            detail = xaiSubscriptionDetail(payload, secrets)
            error("xAI: completion failed or truncated" * (isempty(detail) ? "" : ": " * detail))
        elseif kind == "response.output_text.delta"
            completed && error("xAI: text received after terminal response")
            delta = get(event, "delta", nothing)
            delta isa AbstractString || error("xAI: invalid text delta")
            print(content, delta)
        elseif kind in ("response.reasoning_summary_text.delta", "response.reasoning_text.delta")
            delta = get(event, "delta", nothing)
            delta isa AbstractString || error("xAI: invalid reasoning delta")
            print(reasoning, delta)
            onThinking === nothing || onThinking(delta)
        elseif kind == "response.completed"
            completed && error("xAI: duplicate terminal response")
            terminal = get(event, "response", nothing)
            terminal isa AbstractDict || error("xAI: invalid terminal response")
            terminalContent, terminalReasoning = xaiSubscriptionOutput(terminal)
            completed = true
        end
    end
    completed || error("xAI: stream ended before a completed response; output may be truncated")
    deltaContent, deltaReasoning = String(take!(content)), String(take!(reasoning))
    isempty(terminalContent) && (terminalContent = deltaContent)
    isempty(terminalReasoning) && (terminalReasoning = deltaReasoning)
    isempty(strip(terminalContent)) && error("xAI: completion contains no assistant text")
    if onThinking !== nothing && isempty(deltaReasoning) && !isempty(terminalReasoning)
        onThinking(terminalReasoning)
    end
    return withReasoning(terminalContent, terminalReasoning)
end

function subscriptionComplete(::Val{:xai}, credential::Dict{String,Any}, model::AbstractString,
        messages::Vector{OllamaMessage}; temperature::Real = 0.2, maxTokens::Integer = 4096,
        onThinking = nothing, jsonMode::Bool = false, timeoutS::Real = 120.0)::String
    maxTokens > 0 && isfinite(timeoutS) && timeoutS > 0 || error("xAI: invalid completion limits")
    xaiSubscriptionSecret(model, "model")
    input = Dict{String,Any}[]
    for message in messages
        message.role in ("system", "user", "assistant") || error("xAI: unsupported conversation role")
        message.images === nothing || isempty(message.images) || error("xAI: image messages are not supported by this text adapter")
        message.tool_calls === nothing || isempty(message.tool_calls) || error("xAI: tool call messages are not supported by this text adapter")
        push!(input, Dict("type" => "message", "role" => message.role,
            "content" => something(message.content, "")))
    end
    headers = xaiSubscriptionHeaders(credential; model, stream = true)
    push!(headers, "Content-Type" => "application/json")
    # The CLI proxy omits temperature/max_output_tokens; JSON instructions already live in the prompt.
    body = Dict("model" => String(model), "input" => input, "stream" => true,
        "store" => false, "reasoning" => Dict("summary" => "detailed"), "prompt_cache_key" => string(uuid4()))
    response = subscriptionRequest("POST", XAI_SUBSCRIPTION_PROXY * "/responses", headers, JSON3.write(body); timeoutS)
    return xaiSubscriptionCompletion(response, credential; onThinking)
end
