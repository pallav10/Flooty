const SUBSCRIPTION_NAMES = ("github-copilot" => "GitHub Copilot",
                            "claude-code" => "Claude Code",
                            "xai" => "xAI / Grok")
const SUBSCRIPTION_HTTP = Ref{Union{Nothing,Function}}(nothing)
const SUBSCRIPTION_LOCK = ReentrantLock()
const SUBSCRIPTION_AUTH_LOCKS = Dict(id => ReentrantLock() for (id, _) in SUBSCRIPTION_NAMES)
const SUBSCRIPTION_LOGIN_LOCKS = Dict(id => ReentrantLock() for (id, _) in SUBSCRIPTION_NAMES)
const SUBSCRIPTION_CREDENTIALS = Dict{String,Union{Nothing,Dict{String,Any}}}()
const SUBSCRIPTION_CONNECTIONS = Dict{String,Bool}()
const SUBSCRIPTION_MODELS = Dict{String,Vector{String}}()
const SUBSCRIPTION_MODEL_ERRORS = Dict{String,String}()
const SUBSCRIPTION_REFRESHING = Set{String}()

function subscriptionKind(provider::AbstractString)
    provider == "github-copilot" && return Val(:github_copilot)
    provider == "claude-code" && return Val(:claude_code)
    provider == "xai" && return Val(:xai)
    throw(ArgumentError("Unknown subscription provider."))
end

function subscriptionModel(model::AbstractString)
    parts = split(String(model), '/'; limit = 2)
    length(parts) == 2 || return nothing
    any(first(p) == parts[1] for p in SUBSCRIPTION_NAMES) || return nothing
    isempty(parts[2]) && throw(ArgumentError("Missing subscription model name."))
    return (provider = parts[1], model = parts[2])
end

function subscriptionRequest(method::AbstractString, url::AbstractString,
                             headers = Pair{String,String}[], body = "";
                             timeoutS::Real = 120.0)::HTTP.Response
    isfinite(timeoutS) && timeoutS > 0 || throw(ArgumentError("Invalid request timeout."))
    transport = SUBSCRIPTION_HTTP[]
    transport === nothing || return Base.invokelatest(transport, method, url, headers, body)
    uri = HTTP.URI(url)
    uri.scheme == "https" || throw(ArgumentError("Subscription requests require HTTPS."))
    try
        return HTTP.request(method, url, headers, body; status_exception = false,
                            redirect = false, retry = false, connect_timeout = ceil(Int, min(15, timeoutS)),
                            readtimeout = ceil(Int, timeoutS))
    catch err
        err isa InterruptException && rethrow()
        error("Subscription network request failed ($(nameof(typeof(err)))).")
    end
end

function subscriptionJson(response::HTTP.Response; statuses = (200,))::Dict{String,Any}
    response.status in statuses || error("Subscription provider returned HTTP $(response.status).")
    parsed = try
        JSON3.read(response.body, Dict{String,Any})
    catch
        error("Subscription provider returned invalid JSON.")
    end
    return parsed
end

subscriptionForm(fields::AbstractDict)::String = join(
    (HTTP.URIs.escapeuri(string(k)) * "=" * HTTP.URIs.escapeuri(string(v)) for (k, v) in fields), "&")
subscriptionBase64Url(bytes) = replace(base64encode(bytes), '+' => '-', '/' => '_', "=" => "")

function newSubscriptionPkce()
    rng = Random.RandomDevice()
    verifier = subscriptionBase64Url(rand(rng, UInt8, 32))
    return (; verifier, challenge = subscriptionBase64Url(SHA.sha256(verifier)),
            state = subscriptionBase64Url(rand(rng, UInt8, 32)))
end

function subscriptionStateMatches(a::AbstractString, b::AbstractString)::Bool
    ncodeunits(a) == ncodeunits(b) || return false
    diff = UInt8(0)
    for (x, y) in zip(codeunits(a), codeunits(b))
        diff |= x ⊻ y
    end
    return diff == 0
end

function subscriptionCallback(input::AbstractString, redirectUri::AbstractString,
                              state::AbstractString)::String
    actual, expected = try
        (HTTP.URI(strip(input)), HTTP.URI(redirectUri))
    catch
        throw(ArgumentError("Paste the full authorization redirect URL."))
    end
    (actual.scheme == expected.scheme && actual.host == expected.host &&
     actual.port == expected.port && actual.path == expected.path &&
     isempty(actual.userinfo) && isempty(actual.fragment)) ||
        throw(ArgumentError("The authorization redirect URL does not match this login."))
    fields = Dict{String,String}()
    for part in split(actual.query, '&'; keepempty = false)
        pair = split(part, '='; limit = 2)
        key = HTTP.URIs.unescapeuri(replace(pair[1], '+' => ' '))
        haskey(fields, key) && throw(ArgumentError("Duplicate authorization callback field."))
        fields[key] = length(pair) == 2 ? HTTP.URIs.unescapeuri(replace(pair[2], '+' => ' ')) : ""
    end
    subscriptionStateMatches(get(fields, "state", ""), state) ||
        throw(ArgumentError("Authorization state mismatch. Restart sign-in."))
    haskey(fields, "error") && throw(ArgumentError("Authorization was declined by the provider."))
    code = get(fields, "code", "")
    isempty(strip(code)) && throw(ArgumentError("The redirect URL does not contain an authorization code."))
    return code
end

mutable struct SubscriptionLogin
    id::String
    provider::String
    domain::String
    cancelled::Bool
    expiresAt::Float64
    status::String
    kind::String
    authorizationUrl::String
    userCode::String
    instructions::String
    error::String
    input::Channel{String}
    lock::ReentrantLock
end

function SubscriptionLogin(provider::AbstractString; ttl::Real = 600, domain::AbstractString = "")
    subscriptionKind(provider)
    selectedDomain = if provider == "github-copilot"
        normalizeCopilotDomain(domain)
    else
        isempty(strip(domain)) || throw(ArgumentError("A GitHub host applies only to Copilot sign-in."))
        ""
    end
    return SubscriptionLogin(string(uuid4()), String(provider), selectedDomain, false, time() + ttl,
                             "starting", "", "", "", "", "", Channel{String}(1), ReentrantLock())
end

const SUBSCRIPTION_LOGINS = Dict{String,SubscriptionLogin}()

function updateSubscriptionLogin!(attempt::SubscriptionLogin; kind = attempt.kind,
                                  authorizationUrl = attempt.authorizationUrl,
                                  userCode = attempt.userCode, instructions = attempt.instructions,
                                  expiresAt = attempt.expiresAt, status = "waiting")
    lock(attempt.lock) do
        checkSubscriptionLogin(attempt)
        attempt.kind = String(kind)
        attempt.authorizationUrl = String(authorizationUrl)
        attempt.userCode = String(userCode)
        attempt.instructions = String(instructions)
        attempt.expiresAt = Float64(expiresAt)
        attempt.status = String(status)
    end
    return nothing
end

function checkSubscriptionLogin(attempt::SubscriptionLogin)
    attempt.cancelled && throw(InterruptException())
    time() < attempt.expiresAt || throw(ArgumentError("Sign-in expired. Start again."))
    return nothing
end

function subscriptionSleep(attempt::SubscriptionLogin, seconds::Real)
    until = time() + max(0, seconds)
    while time() < until
        checkSubscriptionLogin(attempt)
        sleep(min(0.1, max(0, until - time())))
    end
    checkSubscriptionLogin(attempt)
    return nothing
end

function waitSubscriptionInput!(attempt::SubscriptionLogin)::String
    while !isready(attempt.input)
        subscriptionSleep(attempt, 0.1)
    end
    checkSubscriptionLogin(attempt)
    return take!(attempt.input)
end

function storedSubscriptionCredential(provider::AbstractString)
    subscriptionKind(provider)
    provider == "claude-code" && return claudeCodeCredential()
    return lock(SUBSCRIPTION_AUTH_LOCKS[provider]) do
        loaded, value = lock(SUBSCRIPTION_LOCK) do
            (haskey(SUBSCRIPTION_CREDENTIALS, provider), get(SUBSCRIPTION_CREDENTIALS, provider, nothing))
        end
        if !loaded
            secret = Base.invokelatest(SUBSCRIPTION_STORE_READ[], String(provider))
            value = if secret === nothing
                nothing
            else
                try
                    JSON3.read(secret, Dict{String,Any})
                catch
                    error("Stored subscription credentials are invalid. Sign in again.")
                end
            end
            lock(SUBSCRIPTION_LOCK) do
                SUBSCRIPTION_CREDENTIALS[provider] = value
            end
        end
        return value === nothing ? nothing : copy(value)
    end
end

function saveSubscriptionCredential!(provider::AbstractString, credential::Dict{String,Any})
    subscriptionKind(provider)
    githubDomain = provider == "github-copilot" ?
        normalizeCopilotDomain(get(credential, "githubDomain", "")) : ""
    if provider == "github-copilot" && get(credential, "githubDomain", nothing) != githubDomain
        credential = copy(credential)
        credential["githubDomain"] = githubDomain
    end
    if provider == "claude-code"
        get(credential, "mode", "") == "claude-code" || error("Invalid Claude Code connection.")
    else
        access = get(credential, "access", "")
        access isa AbstractString && !isempty(access) && !any(iscntrl, access) ||
            error("Provider did not return a valid access credential.")
        expires = get(credential, "expiresAt", nothing)
        expires isa Real && !(expires isa Bool) && isfinite(expires) && expires >= 0 ||
            error("Provider returned an invalid credential expiry.")
        lock(SUBSCRIPTION_AUTH_LOCKS[provider]) do
            Base.invokelatest(SUBSCRIPTION_STORE_WRITE[], String(provider), JSON3.write(credential))
            lock(SUBSCRIPTION_LOCK) do
                if provider == "github-copilot"
                    previous = get(SUBSCRIPTION_CREDENTIALS, provider, nothing)
                    previousDomain = previous === nothing ? "" : get(previous, "githubDomain", "github.com")
                    if previousDomain != githubDomain
                        delete!(SUBSCRIPTION_MODELS, provider)
                        delete!(SUBSCRIPTION_MODEL_ERRORS, provider)
                    end
                end
                SUBSCRIPTION_CREDENTIALS[provider] = copy(credential)
            end
        end
    end
    lock(SUBSCRIPTION_LOCK) do
        SUBSCRIPTION_CONNECTIONS[provider] = true
    end
    return nothing
end

function subscriptionCredential(provider::AbstractString)::Dict{String,Any}
    return lock(SUBSCRIPTION_AUTH_LOCKS[provider]) do
        credential = storedSubscriptionCredential(provider)
        credential === nothing && error("Not signed in to this provider. Use /login.")
        expires = get(credential, "expiresAt", 0)
        if expires > 0 && expires <= time() + 60
            credential = refreshSubscriptionCredential(subscriptionKind(provider), credential)
            saveSubscriptionCredential!(provider, credential)
        end
        return credential
    end
end

function subscriptionModelScopeMatches(provider::AbstractString, credential::AbstractDict)::Bool
    provider == "github-copilot" || return true
    current = get(SUBSCRIPTION_CREDENTIALS, provider, nothing)
    return current !== nothing &&
           get(current, "githubDomain", "github.com") == get(credential, "githubDomain", "github.com")
end

function refreshSubscriptionModels!(provider::AbstractString)::Vector{String}
    credential = subscriptionCredential(provider)
    models = try
        offered = subscriptionModelList(subscriptionKind(provider), credential)
        filter!(!isempty, offered)
        sort!(unique!(offered))
        isempty(offered) && error("The subscription provider returned no available models.")
        offered
    catch
        replacement = lock(SUBSCRIPTION_LOCK) do
            subscriptionModelScopeMatches(provider, credential) && return nothing
            cached = get(SUBSCRIPTION_MODELS, provider, nothing)
            return cached === nothing ? String[] : cached
        end
        replacement === nothing || return replacement
        rethrow()
    end
    return lock(SUBSCRIPTION_LOCK) do
        # A host switch also invalidates catalog requests already in flight.
        if !subscriptionModelScopeMatches(provider, credential)
            cached = get(SUBSCRIPTION_MODELS, provider, nothing)
            return cached === nothing ? String[] : cached
        end
        SUBSCRIPTION_MODELS[provider] = models
        delete!(SUBSCRIPTION_MODEL_ERRORS, provider)
        return models
    end
end

function availableSubscriptionModels()::Vector{String}
    return lock(SUBSCRIPTION_LOCK) do
        sort!([provider * "/" * model for (provider, models) in SUBSCRIPTION_MODELS for model in models])
    end
end

function refreshConnectedSubscriptionModels!()
    for (provider, _) in SUBSCRIPTION_NAMES
        start = lock(SUBSCRIPTION_LOCK) do
            provider in SUBSCRIPTION_REFRESHING && return false
            push!(SUBSCRIPTION_REFRESHING, provider)
            return true
        end
        start || continue
        @async try
            connected = storedSubscriptionCredential(provider) !== nothing
            lock(SUBSCRIPTION_LOCK) do
                SUBSCRIPTION_CONNECTIONS[provider] = connected
            end
            connected && refreshSubscriptionModels!(provider)
        catch err
            lock(SUBSCRIPTION_LOCK) do
                SUBSCRIPTION_MODEL_ERRORS[provider] = sprint(showerror, err)
            end
        finally
            lock(SUBSCRIPTION_LOCK) do
                delete!(SUBSCRIPTION_REFRESHING, provider)
            end
        end
    end
    return nothing
end

function subscriptionProviders()
    return lock(SUBSCRIPTION_LOCK) do
        github = get(SUBSCRIPTION_CREDENTIALS, "github-copilot", nothing)
        githubDomain = github === nothing ? "github.com" : get(github, "githubDomain", "github.com")
        [(id = id, name = name, connected = get(SUBSCRIPTION_CONNECTIONS, id, false),
          domain = id == "github-copilot" ? githubDomain : "",
          checking = id in SUBSCRIPTION_REFRESHING,
          models = copy(get(SUBSCRIPTION_MODELS, id, String[])),
          error = get(SUBSCRIPTION_MODEL_ERRORS, id, "")) for (id, name) in SUBSCRIPTION_NAMES]
    end
end

function subscriptionLoginState(id::AbstractString)
    attempt = lock(SUBSCRIPTION_LOCK) do
        get(SUBSCRIPTION_LOGINS, String(id), nothing)
    end
    attempt === nothing && throw(ArgumentError("Sign-in is no longer active."))
    return lock(attempt.lock) do
        (; id = attempt.id, provider = attempt.provider, domain = attempt.domain, status = attempt.status,
         kind = attempt.kind, authorizationUrl = attempt.authorizationUrl,
         userCode = attempt.userCode, instructions = attempt.instructions,
         expiresAt = attempt.expiresAt, error = attempt.error)
    end
end

function beginSubscriptionLogin(provider::AbstractString; domain::AbstractString = "")
    attempt = SubscriptionLogin(provider; domain = domain)
    lock(SUBSCRIPTION_LOGIN_LOCKS[provider]) do
        previous = lock(SUBSCRIPTION_LOCK) do
            [old for old in values(SUBSCRIPTION_LOGINS) if old.provider == provider]
        end
        for old in previous
            lock(old.lock) do
                old.cancelled = true
            end
        end
        lock(SUBSCRIPTION_LOCK) do
            for old in previous
                delete!(SUBSCRIPTION_LOGINS, old.id)
            end
            SUBSCRIPTION_LOGINS[attempt.id] = attempt
        end
    end
    @async try
        credential = loginSubscription!(subscriptionKind(provider), attempt)
        lock(SUBSCRIPTION_AUTH_LOCKS[provider]) do
            lock(attempt.lock) do
                checkSubscriptionLogin(attempt)
                saveSubscriptionCredential!(provider, credential)
                attempt.status = "loading_models"
            end
        end
        refreshSubscriptionModels!(provider)
        lock(attempt.lock) do
            checkSubscriptionLogin(attempt)
            attempt.status = "connected"
        end
    catch err
        lock(attempt.lock) do
            attempt.status = attempt.cancelled || err isa InterruptException ? "cancelled" : "error"
            attempt.error = attempt.status == "cancelled" ? "" : sprint(showerror, err)
        end
    end
    return subscriptionLoginState(attempt.id)
end

function submitSubscriptionLogin!(id::AbstractString, input::AbstractString)
    attempt = lock(SUBSCRIPTION_LOCK) do
        get(SUBSCRIPTION_LOGINS, String(id), nothing)
    end
    attempt === nothing && throw(ArgumentError("Sign-in is no longer active."))
    lock(attempt.lock) do
        checkSubscriptionLogin(attempt)
        attempt.kind == "paste" && attempt.status == "waiting" ||
            throw(ArgumentError("This sign-in is not waiting for a redirect URL."))
        isempty(strip(input)) && throw(ArgumentError("Paste the full redirect URL."))
        isready(attempt.input) && throw(ArgumentError("Authorization is already being completed."))
        put!(attempt.input, String(strip(input)))
        attempt.status = "exchanging"
    end
    return nothing
end

function cancelSubscriptionLogin!(id::AbstractString)
    attempt = lock(SUBSCRIPTION_LOCK) do
        get(SUBSCRIPTION_LOGINS, String(id), nothing)
    end
    attempt === nothing && return nothing
    lock(attempt.lock) do
        if !(attempt.status in ("connected", "error", "cancelled"))
            attempt.cancelled = true
            attempt.status = "cancelled"
        end
    end
    return nothing
end
