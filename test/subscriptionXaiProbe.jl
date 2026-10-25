using Test
using HTTP
using JSON3
using Base64
using SHA
using Flooty

# Only synthetic tokens; this probe never opens a browser, writes credentials, or uses the network.
xaiProbeJwt(claims) = "header." * rstrip(replace(base64encode(JSON3.write(claims)), '+' => '-', '/' => '_'), '=') * ".signature"
xaiProbeJson(payload; status = 200) = HTTP.Response(status, JSON3.write(payload))
xaiProbeEvent(event) = "data: " * JSON3.write(event) * "\n\n"

function xaiProbeLoginState(id, statuses)
    timedwait(() -> Flooty.subscriptionLoginState(id).status in statuses, 3; pollint = 0.01) == :ok ||
        error("Synthetic xAI login did not reach expected state")
    return Flooty.subscriptionLoginState(id)
end

@testset "xAI real subscription protocol" begin
    previous = Flooty.SUBSCRIPTION_HTTP[]
    previousStoreRead, previousStoreWrite = Flooty.SUBSCRIPTION_STORE_READ[], Flooty.SUBSCRIPTION_STORE_WRITE[]
    caches = (Flooty.SUBSCRIPTION_CREDENTIALS, Flooty.SUBSCRIPTION_MODELS,
              Flooty.SUBSCRIPTION_MODEL_ERRORS, Flooty.SUBSCRIPTION_CONNECTIONS)
    cached = [(cache, haskey(cache, "xai"), get(cache, "xai", nothing)) for cache in caches]
    loginIds = String[]
    memoryStore = Dict{String,String}()
    Flooty.SUBSCRIPTION_STORE_READ[] = provider -> get(memoryStore, provider, nothing)
    Flooty.SUBSCRIPTION_STORE_WRITE[] = (provider, secret) -> (memoryStore[provider] = secret; nothing)
    calls = Any[]
    issuer = "https://auth.x.ai"
    proxy = "https://cli-chat-proxy.grok.com/v1"
    discovery = Dict{String,Any}("issuer" => issuer,
        "authorization_endpoint" => issuer * "/oauth2/authorize",
        "token_endpoint" => issuer * "/oauth2/token",
        "code_challenge_methods_supported" => ["S256"])
    access = xaiProbeJwt(Dict("sub" => "test-account", "exp" => floor(Int, time()) + 3600))
    credential = Dict{String,Any}("access" => access, "refresh" => "old-refresh", "expiresAt" => 1.0,
        "accountId" => "test-account")
    tokenReply = Ref{Any}(Dict("access_token" => access, "refresh_token" => "rotated-refresh", "expires_in" => 3600))
    Flooty.SUBSCRIPTION_HTTP[] = function(method, url, headers, body)
        push!(calls, (; method, url, headers = Dict(headers), body))
        url == issuer * "/.well-known/openid-configuration" && return xaiProbeJson(discovery)
        url == issuer * "/oauth2/token" && return xaiProbeJson(tokenReply[])
        error("Probe rejected unexpected endpoint")
    end
    try
        @testset "pinned discovery and callback state" begin
            for bad in ("http://auth.x.ai/oauth2/token", "https://evil.test/token",
                    "https://auth.x.ai.evil.test/token", "https://evil.test@auth.x.ai/token",
                    "https://auth.x.ai:8443/token", "https://auth.x.ai/token#fragment",
                    "https://auth.x.ai/token?redirect_uri=https://evil.test")
                @test_throws Exception Flooty.xaiSubscriptionEndpoint(bad, "token endpoint")
            end
            @test Flooty.xaiSubscriptionEndpoint(issuer * "/oauth2/token", "token endpoint") == issuer * "/oauth2/token"
            for field in ("authorization_endpoint", "token_endpoint", "issuer")
                original = discovery[field]
                discovery[field] = "https://evil.test/token"
                count = length(calls)
                @test_throws Exception Flooty.refreshSubscriptionCredential(Val(:xai), credential)
                @test length(calls) == count + 1
                @test calls[end].url == issuer * "/.well-known/openid-configuration"
                @test !haskey(calls[end].headers, "Authorization")
                discovery[field] = original
            end
            before = length(calls)
            redirect = Flooty.XAI_SUBSCRIPTION_REDIRECT
            @test Flooty.subscriptionCallback(redirect * "?code=code-one&state=expected", redirect, "expected") == "code-one"
            for callback in ("code-one", redirect * "?code=code-one", redirect * "?code=code-one&state=wrong",
                    "http://localhost:1456/callback?code=code-one&state=expected",
                    "http://127.0.0.1:1457/callback?code=code-one&state=expected",
                    "http://127.0.0.1:1456/other?code=code-one&state=expected",
                    redirect * "?code=code-one&state=expected&state=expected",
                    redirect * "?code=code-one&code=code-two&state=expected")
                @test_throws Exception Flooty.subscriptionCallback(callback, redirect, "expected")
            end
            @test length(calls) == before
            cancelled = Flooty.SubscriptionLogin("xai")
            cancelled.cancelled = true
            @test_throws InterruptException Flooty.loginSubscription!(Val(:xai), cancelled)
            @test length(calls) == before
            expired = Flooty.SubscriptionLogin("xai")
            expired.expiresAt = time() - 1
            @test_throws Exception Flooty.loginSubscription!(Val(:xai), expired)
            @test length(calls) == before
        end

        @testset "PKCE full redirect paste and cancellation" begin
            refreshTransport = Flooty.SUBSCRIPTION_HTTP[]
            Flooty.SUBSCRIPTION_HTTP[] = function(method, url, headers, body)
                url == proxy * "/models" && return xaiProbeJson(Dict("data" => [Dict("id" => "grok-live-catalog")]))
                return refreshTransport(method, url, headers, body)
            end
            for invalid in (true, false)
                started = Flooty.beginSubscriptionLogin("xai")
                push!(loginIds, started.id)
                waiting = xaiProbeLoginState(started.id, ("waiting",))
                uri = HTTP.URI(waiting.authorizationUrl)
                @test uri.scheme == "https"
                @test uri.host == "auth.x.ai"
                @test uri.path == "/oauth2/authorize"
                @test occursin("code_challenge_method=S256", uri.query)
                @test occursin("response_type=code", uri.query)
                @test occursin("grok-cli%3Aaccess", uri.query)
                state = String(match(r"(?:^|&)state=([^&]+)", uri.query).captures[1])
                before = length(calls)
                callback = Flooty.XAI_SUBSCRIPTION_REDIRECT * "?code=synthetic-code&state=" * (invalid ? "wrong" : state)
                Flooty.submitSubscriptionLogin!(started.id, callback)
                finished = xaiProbeLoginState(started.id, ("connected", "error"))
                if invalid
                    @test finished.status == "error"
                    @test length(calls) == before
                    @test isempty(memoryStore)
                else
                    @test finished.status == "connected"
                    @test haskey(memoryStore, "xai")
                    @test JSON3.read(memoryStore["xai"])["access"] == access
                    exchange = calls[end]
                    @test exchange.url == issuer * "/oauth2/token"
                    @test occursin("grant_type=authorization_code", exchange.body)
                    @test occursin("code=synthetic-code", exchange.body)
                    verifier = String(match(r"(?:^|&)code_verifier=([^&]+)", exchange.body).captures[1])
                    challenge = rstrip(replace(base64encode(SHA.sha256(verifier)), '+' => '-', '/' => '_'), '=')
                    @test occursin("code_challenge=" * challenge, uri.query)
                    @test !occursin(verifier, waiting.authorizationUrl)
                end
            end
            started = Flooty.beginSubscriptionLogin("xai")
            push!(loginIds, started.id)
            xaiProbeLoginState(started.id, ("waiting",))
            before = length(calls)
            Flooty.cancelSubscriptionLogin!(started.id)
            @test xaiProbeLoginState(started.id, ("cancelled",)).status == "cancelled"
            @test length(calls) == before
            Flooty.SUBSCRIPTION_HTTP[] = refreshTransport
        end

        @testset "rotating refresh and expiry" begin
            fresh = Flooty.refreshSubscriptionCredential(Val(:xai), credential)
            @test fresh["access"] == access
            @test fresh["refresh"] == "rotated-refresh"
            @test fresh["expiresAt"] > time()
            @test fresh["accountId"] == "test-account"
            @test calls[end].url == issuer * "/oauth2/token"
            @test calls[end].headers["Content-Type"] == "application/x-www-form-urlencoded"
            @test occursin("grant_type=refresh_token", calls[end].body)
            @test occursin("refresh_token=old-refresh", calls[end].body)
            @test occursin("client_id=b1a00492-073a-47ea-816f-4c329264a828", calls[end].body)
            delete!(tokenReply[], "refresh_token")
            delete!(tokenReply[], "expires_in")
            fresh = Flooty.refreshSubscriptionCredential(Val(:xai), fresh)
            @test fresh["refresh"] == "rotated-refresh"
            @test fresh["expiresAt"] > time()
            tokenReply[] = Dict("access_token" => "opaque-without-expiry")
            @test_throws Exception Flooty.refreshSubscriptionCredential(Val(:xai), fresh)
            tokenReply[] = Dict("access_token" => access, "expires_in" => 3600)
        end

        @testset "authenticated live catalog with pagination" begin
            page = Ref(0)
            Flooty.SUBSCRIPTION_HTTP[] = function(method, url, headers, body)
                page[] += 1
                h = Dict(headers)
                @test method == "GET"
                @test h["Authorization"] == "Bearer " * access
                @test h["x-xai-token-auth"] == "xai-grok-cli"
                @test h["x-grok-user-id"] == "test-account"
                @test h["x-grok-client-identifier"] == "grok-shell"
                if page[] == 1
                    @test url == proxy * "/models"
                    return xaiProbeJson(Dict("data" => [Dict("id" => "grok-test-one"), Dict("id" => "grok-imagine-image")],
                        "has_more" => true, "last_id" => "cursor-one"))
                end
                @test url == proxy * "/models?after=cursor-one"
                return xaiProbeJson(Dict("data" => [Dict("id" => "grok-test-one"), Dict("id" => "grok-test-two")]))
            end
            @test Flooty.subscriptionModelList(Val(:xai), credential) == ["grok-test-one", "grok-test-two"]
            Flooty.SUBSCRIPTION_HTTP[] = (args...) -> xaiProbeJson(Dict("data" => Any[]))
            @test_throws Exception Flooty.subscriptionModelList(Val(:xai), credential)
            Flooty.SUBSCRIPTION_HTTP[] = (args...) -> xaiProbeJson(Dict("data" => [Dict("id" => "grok-test")],
                "has_more" => true, "last_id" => "same-cursor"))
            @test_throws Exception Flooty.subscriptionModelList(Val(:xai), credential)
        end

        messages = [Flooty.OllamaMessage(role = "system", content = "Return a JSON action"),
            Flooty.OllamaMessage(role = "assistant", content = "Prior reply", thinking = "private prior reasoning"),
            Flooty.OllamaMessage(role = "user", content = "Continue")]
        final = Dict("status" => "completed", "output" => [
            Dict("type" => "reasoning", "summary" => [Dict("type" => "summary_text", "text" => "Considered")]),
            Dict("type" => "message", "status" => "completed", "content" => [Dict("type" => "output_text", "text" => "{\"action\":\"done\"}")])])
        stream = xaiProbeEvent(Dict("type" => "response.reasoning_summary_text.delta", "delta" => "Considered")) *
            xaiProbeEvent(Dict("type" => "response.output_text.delta", "delta" => "{\"action\":\"done\"}")) *
            xaiProbeEvent(Dict("type" => "response.completed", "response" => final)) * "data: [DONE]\n\n"
        completionReply = Ref(HTTP.Response(200, ["Content-Type" => "text/event-stream"], stream))
        Flooty.SUBSCRIPTION_HTTP[] = function(method, url, headers, body)
            @test method == "POST"
            @test url == proxy * "/responses"
            h = Dict(headers)
            @test h["Accept"] == "text/event-stream"
            @test h["Authorization"] == "Bearer " * access
            @test h["x-grok-model-override"] == "grok-test-one"
            @test h["x-grok-client-version"] == "1.0.62"
            @test h["x-authenticateresponse"] == "authenticate-response"
            payload = JSON3.read(body, Dict{String,Any})
            @test payload["input"][1] == Dict("type" => "message", "role" => "system", "content" => "Return a JSON action")
            @test payload["input"][2]["content"] == "Prior reply"
            @test !occursin("private prior reasoning", body)
            @test payload["reasoning"]["summary"] == "detailed"
            @test payload["stream"] === true
            @test payload["store"] === false
            @test !haskey(payload, "max_output_tokens")
            @test !haskey(payload, "temperature")
            return completionReply[]
        end
        @testset "real Responses content and terminal handling" begin
            thoughts = String[]
            result = Flooty.subscriptionComplete(Val(:xai), credential, "grok-test-one", messages;
                onThinking = delta -> push!(thoughts, delta), jsonMode = true, timeoutS = 30)
            @test occursin("{\"action\":\"done\"}", result)
            @test occursin("Considered", result)
            @test thoughts == ["Considered"]
            completionReply[] = xaiProbeJson(final)
            @test occursin("{\"action\":\"done\"}", Flooty.subscriptionComplete(Val(:xai), credential, "grok-test-one", messages))
            for payload in ("data: [DONE]\n\n", xaiProbeEvent(Dict("type" => "response.output_text.delta", "delta" => "partial")),
                    xaiProbeEvent(Dict("type" => "response.incomplete", "response" => Dict("status" => "incomplete"))),
                    xaiProbeEvent(Dict("type" => "response.failed", "response" => Dict("error" => Dict("code" => "quota_exceeded")))),
                    "data: not-json\n\n")
                completionReply[] = HTTP.Response(200, payload)
                @test_throws Exception Flooty.subscriptionComplete(Val(:xai), credential, "grok-test-one", messages)
            end
        end
        @testset "billing and account errors without credential leakage" begin
            completionReply[] = xaiProbeJson(Dict("error" => Dict("type" => "billing_error", "code" => "subscription_required",
                "message" => "SuperGrok required; token=" * access * "; refresh=old-refresh")); status = 402)
            failure = try
                Flooty.subscriptionComplete(Val(:xai), credential, "grok-test-one", messages)
                nothing
            catch exception
                sprint(showerror, exception)
            end
            @test failure isa String
            @test occursin("402", failure)
            @test occursin("billing_error", failure)
            @test occursin("subscription_required", failure)
            @test occursin("SuperGrok required", failure)
            @test !occursin(access, failure)
            @test !occursin("old-refresh", failure)
            for status in (301, 401, 403, 426, 429)
                completionReply[] = xaiProbeJson(Dict("error" => Dict("code" => "account_gate", "message" => "Access denied")); status)
                @test_throws Exception Flooty.subscriptionComplete(Val(:xai), credential, "grok-test-one", messages)
            end
        end
    finally
        Flooty.SUBSCRIPTION_HTTP[] = previous
        Flooty.SUBSCRIPTION_STORE_READ[] = previousStoreRead
        Flooty.SUBSCRIPTION_STORE_WRITE[] = previousStoreWrite
        for (cache, present, value) in cached
            present ? (cache["xai"] = value) : delete!(cache, "xai")
        end
        for id in loginIds
            haskey(Flooty.SUBSCRIPTION_LOGINS, id) || continue
            Flooty.cancelSubscriptionLogin!(id)
            delete!(Flooty.SUBSCRIPTION_LOGINS, id)
        end
    end
end
