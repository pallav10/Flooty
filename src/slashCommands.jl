const SLASH_COMMANDS = [(name = "login", description = "Connect a model subscription")]

slashCommandCatalog() = SLASH_COMMANDS

function dispatchSlashCommand(text::AbstractString, sessionId::AbstractString = "")
    candidate = strip(text)
    occursin(r"^/(?:[A-Za-z][A-Za-z0-9_-]*)?(?:\s.*)?$"s, candidate) || return (handled = false,)
    parts = split(candidate; limit = 2)
    name = SubString(first(parts), 2)
    index = findfirst(command -> command.name == name, SLASH_COMMANDS)
    index === nothing && return (handled = true, action = "error",
                                 message = "Unknown action. Type / to see available actions.")
    length(parts) == 1 || return (handled = true, action = "error",
                                 message = "Use the action without arguments; private input belongs in its dialog.")
    return (handled = true, action = SLASH_COMMANDS[index].name)
end

function subscriptionUiAction(payload)
    operation = String(get(payload, :operation, "providers"))
    provider = String(get(payload, :provider, ""))
    id = String(get(payload, :id, ""))
    if operation in ("providers", "refresh")
        operation == "refresh" && refreshConnectedSubscriptionModels!()
        return (providers = subscriptionProviders(),)
    elseif operation == "begin"
        return (login = beginSubscriptionLogin(provider; domain = String(get(payload, :domain, ""))),)
    elseif operation == "status"
        return (login = subscriptionLoginState(id), providers = subscriptionProviders())
    elseif operation == "submit"
        submitSubscriptionLogin!(id, String(get(payload, :redirectUrl, "")))
        return (login = subscriptionLoginState(id),)
    elseif operation == "cancel"
        cancelSubscriptionLogin!(id)
        return (;)
    elseif operation == "use"
        subscriptionKind(provider)
        model = String(get(payload, :model, ""))
        offered = lock(SUBSCRIPTION_LOCK) do
            model in get(SUBSCRIPTION_MODELS, provider, String[])
        end
        offered || throw(ArgumentError("Choose a model from this provider's available models."))
        sessionId = String(get(payload, :session_id, ""))
        return (model = selectAgentModel(provider * "/" * model, sessionId),)
    elseif operation == "open"
        state = subscriptionLoginState(id)
        url = state.authorizationUrl
        uri = HTTP.URI(url)
        uri.scheme == "https" && isempty(uri.userinfo) ||
            throw(ArgumentError("No trusted browser sign-in URL is available."))
        Sys.isapple() || throw(ArgumentError("Open the displayed sign-in link in your browser."))
        run(pipeline(`open $url`; stdout = devnull, stderr = devnull); wait = false)
        return (;)
    end
    throw(ArgumentError("Unknown subscription action."))
end
