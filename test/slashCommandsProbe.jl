using Test, HTTP, JSON3
using Flooty

@testset "Local commands and subscription session routing" begin
    @test Flooty.dispatchSlashCommand("/login").action == "login"
    @test Flooty.dispatchSlashCommand("  /login  ").handled
    @test !Flooty.dispatchSlashCommand("Explain /login").handled
    @test !Flooty.dispatchSlashCommand("/Users/example/project/file.jl").handled
    @test !Flooty.dispatchSlashCommand("```\n/login\n```").handled
    @test Flooty.dispatchSlashCommand("/unknown").action == "error"
    @test Flooty.dispatchSlashCommand("/").action == "error"
    privateArgument = Flooty.dispatchSlashCommand("/login do-not-record-this")
    @test privateArgument.handled && privateArgument.action == "error"
    @test !occursin("do-not-record-this", privateArgument.message)

    previousConfig = Flooty.AGENT_CONFIG[]
    previousAt, previousModels = Flooty.MODEL_LIST_AT[], copy(Flooty.MODEL_LIST_CACHE[])
    previousHttp = Flooty.SUBSCRIPTION_HTTP[]
    previousRead, previousWrite = Flooty.SUBSCRIPTION_STORE_READ[], Flooty.SUBSCRIPTION_STORE_WRITE[]
    previousCli = Flooty.SUBSCRIPTION_CLAUDE_PROCESS[]
    memory = Dict{String,String}()
    a, b = Flooty.ChatSession(), Flooty.ChatSession()
    browser = Flooty.BrowserSession()
    Flooty.registerSession!.((a, b, browser))
    savedCredentials = copy(Flooty.SUBSCRIPTION_CREDENTIALS)
    savedConnections = copy(Flooty.SUBSCRIPTION_CONNECTIONS)
    try
        Flooty.AGENT_CONFIG[] = Flooty.AgentModelConfig(actorModel="local-default", monitorModel="local-monitor",
            apiKey="unrelated-endpoint-key", maxOutputTokens=1873)
        Flooty.MODEL_LIST_AT[] = time()
        Flooty.MODEL_LIST_CACHE[] = ["local-default"]
        Flooty.SUBSCRIPTION_STORE_READ[] = provider -> get(memory, provider, nothing)
        Flooty.SUBSCRIPTION_STORE_WRITE[] = (provider, secret) -> (memory[provider] = secret; nothing)
        Flooty.selectAgentModel("claude-code/sonnet", a.id)
        Flooty.selectAgentModel("xai/grok-session", browser.id)
        @test Flooty.sessionModelConfig(a).actorModel == "claude-code/sonnet"
        @test Flooty.agentModelState(browser.id).current == "xai/grok-session"
        @test Flooty.sessionModelConfig(b).actorModel == "local-default"
        @test Flooty.AGENT_CONFIG[].actorModel == "local-default"
        Flooty.selectMonitorModel("github-copilot/monitor", a.id)
        @test Flooty.sessionModelConfig(a).actorModel == "claude-code/sonnet"
        @test Flooty.sessionModelConfig(a).monitorModel == "github-copilot/monitor"
        @test Flooty.sessionModelConfig(a).maxOutputTokens == 1873
        @test Flooty.conversationFor(a.id).model == "claude-code/sonnet"

        exchangeCount = Ref(0)
        Flooty.saveSubscriptionCredential!("github-copilot", Dict{String,Any}(
            "access"=>"old-access", "refresh"=>"refresh-one", "expiresAt"=>time()-1,
            "apiEndpoint"=>"https://api.githubcopilot.com"))
        Flooty.SUBSCRIPTION_HTTP[] = function(method, url, headers, body)
            if url == "https://github.com/login/oauth/access_token"
                exchangeCount[] += 1
                yield()
                return HTTP.Response(200, JSON3.write(Dict("access_token"=>"new-access",
                    "refresh_token"=>"refresh-two", "expires_in"=>3600)))
            elseif url == "https://api.github.com/copilot_internal/user"
                return HTTP.Response(200, JSON3.write(Dict("endpoints"=>Dict("api"=>"https://api.githubcopilot.com"))))
            end
            error("Unexpected credential destination")
        end
        results = Dict{String,Any}[]
        @sync for _ in 1:4
            @async push!(results, Flooty.subscriptionCredential("github-copilot"))
        end
        @test exchangeCount[] == 1
        @test all(result["access"] == "new-access" for result in results)
        @test JSON3.read(memory["github-copilot"])["refresh"] == "refresh-two"
        @test Flooty.sessionModelConfig(a).apiKey == "unrelated-endpoint-key"

        Flooty.SUBSCRIPTION_CLAUDE_PROCESS[] = function(args, input, timeout, check, environment)
            check()
            if first(args) == "auth"
                return (exitcode=0, stdout="{\"loggedIn\":true}")
            end
            @test !occursin("unrelated-endpoint-key", input)
            @test args[findfirst(==("--model"), args)+1] == "sonnet"
            return (exitcode=0, stdout=JSON3.write(Dict("type"=>"result", "subtype"=>"success",
                "is_error"=>false, "result"=>"{\"reply\":\"subscription reply\"}")))
        end
        completion = Flooty.makeCompleteFn(Flooty.sessionModelConfig(a), "claude-code/sonnet")
        turn = [Flooty.OllamaMessage(role="system", content="Act as the terminal agent"),
            Flooty.OllamaMessage(role="user", content="Finish the task"),
            Flooty.OllamaMessage(role="assistant", content="{\"action\":\"wait\"}"),
            Flooty.OllamaMessage(role="system", content="Current terminal snapshot and turn reminder")]
        @test JSON3.read(completion(turn))["reply"] == "subscription reply"
        @test Flooty.contextLengthFor("xai/grok-session") == Flooty.DEFAULT_CONTEXT_LENGTH
    finally
        Flooty.AGENT_CONFIG[] = previousConfig
        Flooty.MODEL_LIST_AT[], Flooty.MODEL_LIST_CACHE[] = previousAt, previousModels
        Flooty.SUBSCRIPTION_HTTP[] = previousHttp
        Flooty.SUBSCRIPTION_STORE_READ[], Flooty.SUBSCRIPTION_STORE_WRITE[] = previousRead, previousWrite
        Flooty.SUBSCRIPTION_CLAUDE_PROCESS[] = previousCli
        empty!(Flooty.SUBSCRIPTION_CREDENTIALS); merge!(Flooty.SUBSCRIPTION_CREDENTIALS, savedCredentials)
        empty!(Flooty.SUBSCRIPTION_CONNECTIONS); merge!(Flooty.SUBSCRIPTION_CONNECTIONS, savedConnections)
        for session in (a, b, browser)
            Flooty.forgetSessionModel!(session)
            lock(Flooty.SESSIONS_LOCK) do
                delete!(Flooty.SESSIONS, session.id)
            end
            lock(Flooty.CONVERSATIONS_LOCK) do
                delete!(Flooty.CONVERSATIONS, session.id)
            end
        end
    end
end

@testset "Superseded consent cannot overwrite an account" begin
    oldHttp = Flooty.SUBSCRIPTION_HTTP[]
    oldRead, oldWrite = Flooty.SUBSCRIPTION_STORE_READ[], Flooty.SUBSCRIPTION_STORE_WRITE[]
    caches = (Flooty.SUBSCRIPTION_CREDENTIALS, Flooty.SUBSCRIPTION_CONNECTIONS,
              Flooty.SUBSCRIPTION_MODELS, Flooty.SUBSCRIPTION_MODEL_ERRORS, Flooty.SUBSCRIPTION_LOGINS)
    saved = map(copy, caches)
    memory = Dict{String,String}()
    exchanged = Channel{Nothing}(1)
    guard = Flooty.SUBSCRIPTION_AUTH_LOCKS["github-copilot"]
    held = false
    attempt = nothing
    try
        for cache in caches
            empty!(cache)
        end
        Flooty.SUBSCRIPTION_STORE_READ[] = provider -> get(memory, provider, nothing)
        Flooty.SUBSCRIPTION_STORE_WRITE[] = (provider, secret) -> (memory[provider] = secret; nothing)
        Flooty.SUBSCRIPTION_HTTP[] = function(method, url, headers, body)
            payload = if endswith(url, "/device/code")
                Dict("device_code"=>"device", "user_code"=>"ABCD", "verification_uri"=>"https://github.com/login/device",
                     "expires_in"=>60, "interval"=>0.001)
            elseif endswith(url, "/access_token")
                Dict("access_token"=>"superseded-account")
            elseif endswith(url, "/copilot_internal/user")
                put!(exchanged, nothing)
                Dict("endpoints"=>Dict("api"=>"https://api.githubcopilot.com"))
            elseif endswith(url, "/models")
                Dict("data"=>[Dict("id"=>"test-model", "capabilities"=>Dict("type"=>"chat"),
                                  "supported_endpoints"=>["/chat/completions"])])
            else
                error("Unexpected consent destination")
            end
            HTTP.Response(200, JSON3.write(payload))
        end
        lock(guard)
        held = true
        started = Flooty.beginSubscriptionLogin("github-copilot")
        attempt = Flooty.SUBSCRIPTION_LOGINS[started.id]
        take!(exchanged)
        replacement = Flooty.beginSubscriptionLogin("github-copilot")
        Flooty.cancelSubscriptionLogin!(replacement.id)
        unlock(guard)
        held = false
        @test timedwait(() -> attempt.status in ("cancelled", "error", "connected"), 3; pollint=0.01) == :ok
        @test attempt.status == "cancelled"
        @test isempty(memory)
    finally
        held && unlock(guard)
        Flooty.SUBSCRIPTION_HTTP[] = oldHttp
        Flooty.SUBSCRIPTION_STORE_READ[], Flooty.SUBSCRIPTION_STORE_WRITE[] = oldRead, oldWrite
        for (cache, snapshot) in zip(caches, saved)
            empty!(cache); merge!(cache, snapshot)
        end
    end
end
