using Test
using JSON3
using Flooty

@testset "Official Claude Code provider" begin
    previous = Flooty.SUBSCRIPTION_CLAUDE_PROCESS[]
    calls = Any[]
    response = Ref((exitcode=0, stdout="{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}"))
    Flooty.SUBSCRIPTION_CLAUDE_PROCESS[] = function(args, input, timeoutS, check, environment)
        check()
        push!(calls, (args=copy(args), input=input, timeoutS=timeoutS, environment=Dict(environment)))
        return response[]
    end
    try
        credential = Flooty.claudeCodeCredential()
        @test credential == Dict("mode" => "claude-code", "expiresAt" => 0)
        @test !haskey(credential, "access") && !haskey(credential, "refresh")
        login = Flooty.SubscriptionLogin("claude-code")
        @test Flooty.loginSubscription!(Val(:claude_code), login) == credential
        @test login.kind == "browser"
        login.cancelled = true
        countBefore = length(calls)
        @test_throws InterruptException Flooty.loginSubscription!(Val(:claude_code), login)
        @test length(calls) == countBefore
        @test Flooty.refreshSubscriptionCredential(Val(:claude_code), credential) == credential
        response[] = (exitcode=1, stdout="{\"loggedIn\":false}")
        @test Flooty.claudeCodeCredential() === nothing
        @test_throws Exception Flooty.refreshSubscriptionCredential(Val(:claude_code), credential)
        @test_throws Exception Flooty.subscriptionModelList(Val(:claude_code), credential)
        response[] = (exitcode=0, stdout="{\"loggedIn\":\"yes\"}")
        @test_throws Exception Flooty.claudeCodeCredential()
        response[] = (exitcode=2, stdout="private failure details")
        @test_throws Exception Flooty.claudeCodeCredential()

        messages = [Flooty.OllamaMessage(role="system", content="Exact system instructions"),
            Flooty.OllamaMessage(role="user", content="First request"),
            Flooty.OllamaMessage(role="assistant", content="Previous response", thinking="Unsigned thought"),
            Flooty.OllamaMessage(role="user", content="Final request\nwith newline")]
        stream = join(JSON3.write.(Any[
            Dict("type" => "assistant", "message" => Dict("role" => "assistant", "stop_reason" => "end_turn", "content" => [
                Dict("type" => "thinking", "thinking" => "Thought"), Dict("type" => "text", "text" => "Answer")])),
            Dict("type" => "result", "subtype" => "success", "is_error" => false, "result" => "Answer")]), "\n")
        response[] = (exitcode=0, stdout=stream)
        thoughts = String[]
        answer = Flooty.subscriptionComplete(Val(:claude_code), credential, "sonnet", messages; timeoutS=7.0, onThinking=x->push!(thoughts,x))
        @test occursin("Answer", answer) && occursin("Thought", answer)
        @test thoughts == ["Thought"]
        call = calls[end]
        for flag in ("--safe-mode", "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands", "--no-chrome")
            @test flag in call.args
        end
        @test call.args[findfirst(==("--tools"), call.args)+1] == ""
        @test call.args[findfirst(==("--permission-mode"), call.args)+1] == "dontAsk"
        @test call.args[findfirst(==("--system-prompt"), call.args)+1] == "Exact system instructions"
        frame = JSON3.read(call.input)
        @test frame.type == "user"
        @test occursin("Previous response", frame.message.content)
        @test occursin("assistant", frame.message.content)
        @test occursin("Final request\\nwith newline", frame.message.content)
        @test !occursin("Unsigned thought", frame.message.content)
        @test !("--bare" in call.args)
        for result in (
                "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true}",
                "{\"type\":\"assistant\",\"message\":{\"content\":[],\"stop_reason\":\"max_tokens\"}}",
                "{\"type\":\"assistant\",\"message\":{\"content\":[],\"stop_reason\":\"refusal\"}}",
                "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\"}]}}",
                "{\"type\":\"system\",\"subtype\":\"init\"}",
                "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"\"}",
                "not JSON")
            @test_throws Exception Flooty.claudeCodeCompletion(result)
        end
        response[] = (exitcode=1, stdout=stream)
        @test_throws Exception Flooty.subscriptionComplete(Val(:claude_code), credential, "sonnet", messages)
        cancelled = ()->error("cancelled")
        @test_throws Exception Flooty.claudeCodeRun(["auth", "login"]; check=cancelled)
        Flooty.SUBSCRIPTION_CLAUDE_PROCESS[] = function(args, input, timeoutS, check, environment)
            @test timeoutS == 0.01
            error("Claude Code command timed out")
        end
        @test_throws Exception Flooty.subscriptionComplete(Val(:claude_code), credential, "sonnet", messages; timeoutS=0.01)
        pending = Flooty.SubscriptionLogin("claude-code")
        Flooty.SUBSCRIPTION_CLAUDE_PROCESS[] = function(args, input, timeoutS, check, environment)
            check()
            pending.cancelled = true
            check()
            error("Cancellation was not honored")
        end
        @test_throws InterruptException Flooty.loginSubscription!(Val(:claude_code), pending)
    finally
        Flooty.SUBSCRIPTION_CLAUDE_PROCESS[] = previous
    end
end
