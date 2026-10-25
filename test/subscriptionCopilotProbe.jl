# Run with Flooty's project or the resolved flooty-setup environment; no network or credential store writes.
using Test, HTTP, JSON3
import Flooty
using FlootyStreams: OllamaMessage

const COPILOT = Val(:github_copilot)
jsonResponse(value; status=200) = HTTP.Response(status, ["Content-Type" => "application/json"], JSON3.write(value))
sseResponse(events...) = HTTP.Response(200, ["Content-Type" => "text/event-stream"],
    join(["data: " * JSON3.write(event) * "\n\n" for event in events]) * "data: [DONE]\n\n")
accountResponse(base="https://api.business.githubcopilot.com") = jsonResponse(Dict("endpoints" => Dict("api" => base)))
deviceResponse(; interval=0.001, expires=60, verification="https://github.com/login/device") = jsonResponse(Dict(
    "device_code" => "fixture-device-private", "user_code" => "ABCD-EFGH", "verification_uri" => verification,
    "interval" => interval, "expires_in" => expires))
credential(; access="fixture-access", refresh="", expiry=0.0, base="https://api.business.githubcopilot.com") =
    Dict{String,Any}("access" => access, "refresh" => refresh, "expiresAt" => expiry, "apiEndpoint" => base)
modelRow(id="fixture-model"; endpoint="/chat/completions", kind="chat") = Dict(
    "id" => id, "capabilities" => Dict("type" => kind), "supported_endpoints" => [endpoint])
modelResponse(rows=[modelRow()]) = jsonResponse(Dict("data" => rows))
chatDelta(text; reason=nothing, thought="") = Dict("choices" => [Dict("index" => 0,
    "delta" => Dict("content" => text, "reasoning_content" => thought), "finish_reason" => reason)])

function withCopilotHttp(f, handler)
    old = Flooty.SUBSCRIPTION_HTTP[]
    calls = Any[]
    Flooty.SUBSCRIPTION_HTTP[] = (method, url, headers, body) -> begin
        call = (method=String(method), url=String(url), headers=Dict(headers), body=String(body))
        push!(calls, call)
        return handler(call, length(calls))
    end
    try
        return f(calls)
    finally
        Flooty.SUBSCRIPTION_HTTP[] = old
    end
end

function withCopilotStore(f)
    oldRead, oldWrite = Flooty.SUBSCRIPTION_STORE_READ[], Flooty.SUBSCRIPTION_STORE_WRITE[]
    dictionaries = (Flooty.SUBSCRIPTION_CREDENTIALS, Flooty.SUBSCRIPTION_MODELS,
        Flooty.SUBSCRIPTION_MODEL_ERRORS, Flooty.SUBSCRIPTION_LOGINS, Flooty.SUBSCRIPTION_CONNECTIONS)
    saved = map(copy, dictionaries)
    memory = Dict{String,String}()
    Flooty.SUBSCRIPTION_STORE_READ[] = provider -> get(memory, provider, nothing)
    Flooty.SUBSCRIPTION_STORE_WRITE[] = (provider, secret) -> (memory[provider] = secret; nothing)
    try
        return f(memory)
    finally
        for (id, attempt) in Flooty.SUBSCRIPTION_LOGINS
            haskey(saved[4], id) || (attempt.cancelled = true)
        end
        Flooty.SUBSCRIPTION_STORE_READ[], Flooty.SUBSCRIPTION_STORE_WRITE[] = oldRead, oldWrite
        for (dictionary, snapshot) in zip(dictionaries, saved)
            empty!(dictionary)
            merge!(dictionary, snapshot)
        end
    end
end

@testset "Copilot public device consent and lifecycle" begin
    replies = [deviceResponse(), jsonResponse(Dict("error" => "authorization_pending")),
        jsonResponse(Dict("error" => "slow_down", "interval" => 0.001)),
        jsonResponse(Dict("access_token" => "fixture-access", "token_type" => "bearer")), accountResponse(), modelResponse()]
    withCopilotHttp((call, i) -> replies[i]) do calls
        result = withCopilotStore() do memory
            login = Flooty.beginSubscriptionLogin("github-copilot")
            @test timedwait(() -> Flooty.subscriptionLoginState(login.id).status == "waiting", 2; pollint=0.001) == :ok
            waiting = Flooty.subscriptionLoginState(login.id)
            @test waiting.kind == "device"
            @test waiting.userCode == "ABCD-EFGH"
            @test waiting.authorizationUrl == "https://github.com/login/device"
            @test !occursin("fixture-device-private", JSON3.write(waiting))
            @test timedwait(() -> Flooty.subscriptionLoginState(login.id).status in ("connected", "error"), 20; pollint=0.01) == :ok
            @test Flooty.subscriptionLoginState(login.id).status == "connected"
            @test Flooty.SUBSCRIPTION_MODELS["github-copilot"] == ["fixture-model"]
            return JSON3.read(memory["github-copilot"], Dict{String,Any})
        end
        @test result["access"] == "fixture-access"
        @test result["refresh"] == ""
        @test result["expiresAt"] == 0
        @test result["apiEndpoint"] == "https://api.business.githubcopilot.com"
        @test length(calls) == 6
        @test calls[1].url == "https://github.com/login/device/code"
        @test occursin("client_id=Ov23li8tweQw6odWQebz", calls[1].body)
        @test occursin("scope=read%3Auser", calls[1].body)
        @test !occursin("repo", calls[1].body)
        @test all(call -> call.url == "https://github.com/login/oauth/access_token", calls[2:4])
        @test occursin("device_code=fixture-device-private", calls[2].body)
        @test calls[5].url == "https://api.github.com/copilot_internal/user"
        @test calls[5].headers["Authorization"] == "token fixture-access"
        @test !haskey(calls[5].headers, "X-GitHub-Api-Version")
    end
    withCopilotHttp((call, i) -> accountResponse()) do calls
        refreshed = Flooty.refreshSubscriptionCredential(COPILOT, credential())
        @test refreshed["expiresAt"] == 0
        @test refreshed["access"] == "fixture-access"
        @test length(calls) == 1
    end
    withCopilotHttp((call, i) -> i == 1 ? jsonResponse(Dict("access_token" => "rotated",
            "refresh_token" => "rotated-refresh", "expires_in" => 3600)) : accountResponse()) do calls
        refreshed = Flooty.refreshSubscriptionCredential(COPILOT, credential(refresh="old-refresh", expiry=time()-1))
        @test refreshed["access"] == "rotated"
        @test refreshed["refresh"] == "rotated-refresh"
        @test time()+3500 < refreshed["expiresAt"] < time()+3700
        @test occursin("grant_type=refresh_token", calls[1].body)
        @test occursin("refresh_token=old-refresh", calls[1].body)
    end
    withCopilotHttp((call, i) -> i == 1 ? jsonResponse(Dict("access_token" => "rotated",
            "expires_in" => 3600)) : accountResponse()) do calls
        refreshed = Flooty.refreshSubscriptionCredential(COPILOT, credential(refresh="retained", expiry=1))
        @test refreshed["refresh"] == "retained"
    end
end

@testset "Copilot cancellation, expiry, denial, and URL trust" begin
    for code in ("access_denied", "expired_token", "incorrect_device_code", "fixture-private-error")
        withCopilotHttp((call, i) -> i == 1 ? deviceResponse() : jsonResponse(Dict(
                "error" => code, "error_description" => "fixture-secret-error-body"))) do calls
            attempt = Flooty.SubscriptionLogin("github-copilot")
            err = try Flooty.loginSubscription!(COPILOT, attempt); nothing catch error; error end
            @test err isa Exception
            @test !occursin("fixture-secret-error-body", sprint(showerror, err))
            @test !occursin("fixture-private-error", sprint(showerror, err))
            @test length(calls) == 2
        end
    end
    withCopilotHttp((call, i) -> error("must not request")) do calls
        attempt = Flooty.SubscriptionLogin("github-copilot")
        attempt.cancelled = true
        @test_throws InterruptException Flooty.loginSubscription!(COPILOT, attempt)
        @test isempty(calls)
        expired = Flooty.SubscriptionLogin("github-copilot"; ttl=-1)
        @test_throws Exception Flooty.loginSubscription!(COPILOT, expired)
        @test isempty(calls)
    end
    for badUrl in ("https://evil.example/login/device", "http://github.com/login/device",
            "https://github.com@evil.example/login/device", "https://github.com/login/device?code=secret")
        withCopilotHttp((call, i) -> deviceResponse(verification=badUrl)) do calls
            @test_throws Exception Flooty.loginSubscription!(COPILOT, Flooty.SubscriptionLogin("github-copilot"))
            @test length(calls) == 1
        end
    end
    withCopilotHttp((call, i) -> deviceResponse(expires=0.001, interval=10)) do calls
        @test_throws Exception Flooty.loginSubscription!(COPILOT, Flooty.SubscriptionLogin("github-copilot"))
        @test length(calls) == 1
    end
    attempt = Flooty.SubscriptionLogin("github-copilot")
    withCopilotHttp((call, i) -> begin
            i == 1 && return deviceResponse(interval=10)
            error("cancelled poll must not request")
        end) do calls
        canceller = @async begin
            sleep(0.02)
            attempt.cancelled = true
        end
        @test_throws InterruptException Flooty.loginSubscription!(COPILOT, attempt)
        wait(canceller)
        @test length(calls) == 1
    end
    for badBase in ("https://evil.example", "http://api.githubcopilot.com", "https://api.githubcopilot.com.evil.example",
            "https://api.githubcopilot.com:443", "https://api.githubcopilot.com/path", "https://api.githubcopilot.com?x=1",
            "https://fixture@api.githubcopilot.com", "https://api.githubcopilot.com/#fragment")
        withCopilotHttp((call, i) -> accountResponse(badBase)) do calls
            @test_throws Exception Flooty.refreshSubscriptionCredential(COPILOT, credential())
            @test length(calls) == 1
            empty!(calls)
            @test_throws Exception Flooty.subscriptionModelList(COPILOT, credential(base=badBase))
            @test isempty(calls)
        end
    end
    withCopilotHttp((call, i) -> HTTP.Response(401, "fixture-secret-error-body")) do calls
        @test_throws Exception Flooty.refreshSubscriptionCredential(COPILOT, credential())
        @test length(calls) == 1
    end
end

@testset "Copilot authenticated catalog and completion families" begin
    messages = OllamaMessage[OllamaMessage(role="system", content="Only JSON"),
        OllamaMessage(role="user", content="Say done")]
    for (endpoint, suffix, stream) in (
            ("/chat/completions", "/chat/completions", sseResponse(chatDelta("{\"done\":true}"; thought="checking"), chatDelta(""; reason="stop"))),
            ("/v1/messages", "/v1/messages", sseResponse(
                Dict("type" => "content_block_delta", "delta" => Dict("type" => "thinking_delta", "thinking" => "checking")),
                Dict("type" => "content_block_delta", "delta" => Dict("type" => "text_delta", "text" => "{\"done\":true}")),
                Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")), Dict("type" => "message_stop"))),
            ("/responses", "/responses", sseResponse(
                Dict("type" => "response.reasoning_summary_text.delta", "delta" => "checking"),
                Dict("type" => "response.output_text.delta", "delta" => "{\"done\":true}"),
                Dict("type" => "response.completed", "response" => Dict("status" => "completed")))))
        withCopilotHttp((call, i) -> i == 1 ? modelResponse([modelRow(endpoint=endpoint)]) : stream) do calls
            thoughts = String[]
            result = Flooty.subscriptionComplete(COPILOT, credential(), "fixture-model", messages;
                jsonMode=true, maxTokens=1234, onThinking=thought -> push!(thoughts, thought), timeoutS=20)
            @test occursin("{\"done\":true}", result)
            @test thoughts == ["checking"]
            @test calls[1].headers["Copilot-Integration-Id"] == "copilot-developer-cli"
            @test calls[2].url == "https://api.business.githubcopilot.com" * suffix
            @test calls[2].headers["Authorization"] == "Bearer fixture-access"
            @test calls[2].headers["Copilot-Integration-Id"] == "copilot-chat"
            @test calls[2].headers["Editor-Version"] == "copilot/1.0.82"
            @test calls[2].headers["Copilot-Harness-Id"] == "copilot-sdk"
            @test calls[2].headers["Openai-Intent"] == "conversation-agent"
            @test calls[2].headers["X-GitHub-Api-Version"] == "2026-08-01"
            @test calls[2].headers["X-Initiator"] == "user"
            body = JSON3.read(calls[2].body, Dict{String,Any})
            @test body["stream"] == true
            if endpoint == "/v1/messages"
                @test body["system"] == "Only JSON"
                @test body["messages"][1]["role"] == "user"
                @test body["max_tokens"] == 1234
                @test calls[2].headers["anthropic-version"] == "2023-06-01"
            elseif endpoint == "/responses"
                @test body["input"][1]["role"] == "system"
                @test !haskey(body, "max_output_tokens")
            else
                @test body["response_format"]["type"] == "json_object"
                @test body["messages"][1]["role"] == "system"
            end
        end
    end
    withCopilotHttp((call, i) -> modelResponse([modelRow("z"), modelRow("a"), modelRow("z"),
            modelRow("embedding"; kind="embeddings")])) do calls
        @test Flooty.subscriptionModelList(COPILOT, credential()) == ["a", "z"]
    end
    for catalog in (Dict("data" => "wrong"), Dict("data" => ["wrong"]), Dict("error" => "denied"))
        withCopilotHttp((call, i) -> jsonResponse(catalog)) do calls
            @test_throws Exception Flooty.subscriptionModelList(COPILOT, credential())
        end
    end
    withCopilotHttp((call, i) -> i == 1 ? modelResponse() : i == 2 ? HTTP.Response(403, "denied") :
            sseResponse(chatDelta("ok"; reason="stop"))) do calls
        @test Flooty.subscriptionComplete(COPILOT, credential(), "fixture-model", messages) == "ok"
        @test length(calls) == 3
        @test calls[3].headers["Copilot-Integration-Id"] == "copilot-developer-cli"
        @test calls[3].url == calls[2].url
    end
    for badStream in (sseResponse(chatDelta("partial"; reason="length")),
            sseResponse(chatDelta("partial")), sseResponse(chatDelta(""; reason="stop")),
            sseResponse(Dict("error" => Dict("message" => "fixture-secret-error-body"))),
            HTTP.Response(200, "data: {broken-json}\n\n"), HTTP.Response(401, "fixture-secret-error-body"))
        withCopilotHttp((call, i) -> i == 1 ? modelResponse() : badStream) do calls
            err = try Flooty.subscriptionComplete(COPILOT, credential(), "fixture-model", messages); nothing catch error; error end
            @test err isa Exception
            @test !occursin("fixture-secret-error-body", sprint(showerror, err))
            @test length(calls) == 2
        end
    end
    withCopilotHttp((call, i) -> modelResponse()) do calls
        @test_throws Exception Flooty.subscriptionComplete(COPILOT, credential(), "missing-model", messages)
        @test length(calls) == 1
    end
    for (id, expectedPath, stream) in (
            ("claude-sonnet-fixture", "/v1/messages", sseResponse(
                Dict("type" => "content_block_delta", "delta" => Dict("text" => "ok")),
                Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")),
                Dict("type" => "message_stop"))),
            ("grok-4.7", "/responses", sseResponse(
                Dict("type" => "response.output_text.delta", "delta" => "ok"),
                Dict("type" => "response.completed", "response" => Dict("status" => "completed")))))
        row = Dict("id" => id, "capabilities" => Dict("type" => "chat"))
        withCopilotHttp((call, i) -> i == 1 ? modelResponse([row]) : stream) do calls
            @test Flooty.subscriptionComplete(COPILOT, credential(), id, messages) == "ok"
            @test endswith(calls[2].url, expectedPath)
        end
    end
    for (endpoint, invalidStream) in (
            ("/v1/messages", sseResponse(Dict("type" => "content_block_delta", "delta" => Dict("text" => "partial")),
                Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "max_tokens")), Dict("type" => "message_stop"))),
            ("/v1/messages", sseResponse(Dict("type" => "content_block_delta", "delta" => Dict("text" => "partial")),
                Dict("type" => "message_stop"))),
            ("/responses", sseResponse(Dict("type" => "response.output_text.delta", "delta" => "partial"),
                Dict("type" => "response.incomplete", "response" => Dict("status" => "incomplete")))))
        withCopilotHttp((call, i) -> i == 1 ? modelResponse([modelRow(endpoint=endpoint)]) : invalidStream) do calls
            @test_throws Exception Flooty.subscriptionComplete(COPILOT, credential(), "fixture-model", messages)
            @test length(calls) == 2
        end
    end
    for denial in (HTTP.Response(401, "denied"), HTTP.Response(429, "denied"),
            jsonResponse(Dict("error" => Dict("code" => "other")); status=400))
        withCopilotHttp((call, i) -> i == 1 ? modelResponse() : denial) do calls
            @test_throws Exception Flooty.subscriptionComplete(COPILOT, credential(), "fixture-model", messages)
            @test length(calls) == 2
        end
    end
end
println("SUBSCRIPTION_COPILOT_PROBE_PASSED")
