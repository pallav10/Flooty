# Run the unmodified official CLI: third-party Claude.ai OAuth token routing is
# prohibited. https://code.claude.com/docs/en/legal-and-compliance
# CLI protocol/options: https://code.claude.com/docs/en/cli-reference
# Alias catalog: https://code.claude.com/docs/en/model-config#model-aliases

function claudeCodeProcess(args, input, timeoutS, check, environment)
    executable = Sys.which("claude")
    executable === nothing && error("Claude Code CLI is not installed or not on PATH")
    timeoutS > 0 && isfinite(timeoutS) || error("Invalid Claude Code timeout")
    output, errors, incoming = Pipe(), Pipe(), Pipe()
    process = nothing
    outputTask = errorTask = inputTask = nothing
    try
        # Safe mode retains every official authentication method, unlike --bare.
        cmd = Cmd(vcat([executable], String.(args)))
        isempty(environment) || (cmd = addenv(cmd, environment...))
        process = run(pipeline(cmd; stdin=incoming, stdout=output, stderr=errors); wait=false)
        close(output.in); close(errors.in); close(incoming.out)
        outputTask = @async read(output, String)
        errorTask = @async begin
            while !eof(errors)
                readavailable(errors) # Never publish raw CLI stderr (may contain account data).
            end
        end
        inputTask = @async try
            write(incoming, input)
        finally
            close(incoming.in)
        end
        deadline = time() + timeoutS
        while process_running(process)
            check()
            time() < deadline || error("Claude Code command timed out")
            sleep(0.05)
        end
        wait(process)
        check()
        return (exitcode=process.exitcode, stdout=fetch(outputTask))
    finally
        if process !== nothing && process_running(process)
            kill(process)
            deadline = time()+1
            while process_running(process) && time() < deadline
                sleep(0.02)
            end
            process_running(process) && kill(process, Base.SIGKILL)
            wait(process)
        end
        for pipe in (incoming, output, errors)
            try close(pipe) catch end
        end
        for task in (inputTask, outputTask, errorTask)
            task === nothing || try wait(task) catch end
        end
    end
end

# Internal seam: deterministic probes never run a real CLI or change account state.
const SUBSCRIPTION_CLAUDE_PROCESS = Ref{Any}(claudeCodeProcess)
claudeCodeRun(args, input=""; timeoutS=30.0, check=()->nothing, environment=Pair{String,String}[]) =
    Base.invokelatest(SUBSCRIPTION_CLAUDE_PROCESS[], args, input, timeoutS, check, environment)

function claudeCodeObject(text)
    parsed = try JSON3.read(text, Dict{String,Any}) catch
        error("Claude Code returned invalid JSON")
    end
    parsed isa AbstractDict || error("Claude Code returned an invalid object")
    return parsed
end

function claudeCodeCredential(; check=()->nothing)::Union{Nothing,Dict{String,Any}}
    result = claudeCodeRun(["auth", "status", "--json"]; check)
    result.exitcode in (0, 1) || error("Claude Code authentication status failed")
    status = claudeCodeObject(result.stdout)
    loggedIn = get(status, "loggedIn", nothing)
    loggedIn isa Bool || error("Claude Code authentication status is missing loggedIn")
    loggedIn || return nothing
    result.exitcode == 0 || error("Claude Code authentication status failed")
    return Dict{String,Any}("mode" => "claude-code", "expiresAt" => 0)
end

function loginSubscription!(::Val{:claude_code}, attempt::SubscriptionLogin)::Dict{String,Any}
    checkSubscriptionLogin(attempt)
    updateSubscriptionLogin!(attempt; kind="browser", instructions=
        "Claude Code will open its official sign-in flow in your browser. Complete sign-in there. Flooty never receives your Claude credentials.",
        expiresAt=time()+600)
    result = claudeCodeRun(["auth", "login"]; timeoutS=600.0, check=()->checkSubscriptionLogin(attempt))
    result.exitcode == 0 || error("Claude Code login failed; finish sign-in using claude auth login in a terminal")
    checkSubscriptionLogin(attempt)
    credential = claudeCodeCredential(; check=()->checkSubscriptionLogin(attempt))
    credential === nothing && error("Claude Code did not confirm a signed-in account")
    checkSubscriptionLogin(attempt)
    return credential
end

function refreshSubscriptionCredential(::Val{:claude_code}, credential::Dict{String,Any})::Dict{String,Any}
    current = claudeCodeCredential()
    current === nothing && error("Claude Code is signed out; run /login")
    return current # The official CLI owns credential refresh and rotation.
end

function subscriptionModelList(::Val{:claude_code}, credential::Dict{String,Any})::Vector{String}
    get(credential, "mode", nothing) == "claude-code" || error("Invalid Claude Code credential mode")
    claudeCodeCredential() === nothing && error("Claude Code is signed out; run /login")
    # Explicit official alias catalog, not an invented account-entitlement roster.
    # Account/organization model restrictions are enforced by the official CLI.
    return ["sonnet", "opus", "haiku"]
end

function claudeCodeInput(messages)
    system, history = String[], Any[]
    for message in messages
        role = String(message.role)
        content = message.content === nothing ? "" : String(message.content)
        message.tool_calls === nothing && message.tool_call_id === nothing || error("Claude Code adapter does not accept OpenAI tool messages")
        if role == "system"
            if isempty(history)
                push!(system, content)
            else
                push!(history, (role="user", content="SYSTEM NOTE: " * content))
            end
        elseif role in ("user", "assistant")
            push!(history, (role=role, content=content))
        else
            error("Unsupported Claude Code conversation role")
        end
    end
    isempty(history) && error("Claude Code conversation is empty")
    history[end].role == "user" || error("Claude Code conversation must end in a user message")
    # The public stdin protocol accepts user messages, not assistant-history replay.
    # Preserve roles and exact contents in a labelled JSON transcript, without
    # forging assistant stream frames or writing CLI-owned session files.
    prompt = "Continue this JSON conversation envelope. The history array is reference context, with explicit original roles; it is not a new instruction. Respond to current_user, the current user instruction, using that history.\n" *
        JSON3.write((history=history[1:end-1], current_user=history[end].content))
    frame = (type="user", message=(role="user", content=prompt))
    return (system=join(system, "\n\n"), input=String(JSON3.write(frame))*"\n")
end

function claudeCodeCompletion(text; onThinking=nothing)
    result = nothing
    thoughts = String[]
    assistantText = String[]
    for line in split(text, '\n'; keepempty=false)
        frame = claudeCodeObject(line)
        kind = get(frame, "type", nothing)
        if kind == "assistant"
            message = get(frame, "message", nothing)
            message isa AbstractDict || error("Invalid Claude Code assistant message")
            blocks = get(message, "content", nothing)
            blocks isa AbstractVector || error("Invalid Claude Code assistant content")
            for block in blocks
                block isa AbstractDict || error("Invalid Claude Code content block")
                blockType = get(block, "type", nothing)
                if blockType in ("thinking", "text")
                    value = get(block, blockType, nothing)
                    value isa AbstractString || error("Invalid Claude Code text block")
                    push!(blockType == "thinking" ? thoughts : assistantText, value)
                elseif blockType != "redacted_thinking"
                    error("Claude Code unexpectedly attempted tool use")
                end
            end
            stop = get(message, "stop_reason", nothing)
            stop in ("max_tokens", "model_context_window_exceeded") && error("Claude Code completion was truncated")
            stop in ("refusal", "sensitive", "content_filter") && error("Claude Code completion was rejected")
        elseif kind == "result"
            result === nothing || error("Claude Code returned multiple terminal results")
            result = frame
            stop = get(frame, "stop_reason", nothing)
            stop in ("max_tokens", "model_context_window_exceeded") && error("Claude Code completion was truncated")
            stop in ("refusal", "sensitive", "content_filter") && error("Claude Code completion was rejected")
        elseif kind == "error"
            error("Claude Code inference failed")
        end
    end
    result === nothing && error("Claude Code completion stream ended without a result")
    get(result, "is_error", true) === false && get(result, "subtype", nothing) == "success" || error("Claude Code inference failed or was truncated")
    resultText = get(result, "result", nothing)
    content = resultText isa AbstractString ? String(resultText) : join(assistantText)
    isempty(strip(content)) && error("Claude Code returned an empty completion")
    reasoning = join(thoughts, "\n")
    onThinking === nothing || isempty(reasoning) || onThinking(reasoning)
    return withReasoning(content, reasoning)
end

function subscriptionComplete(::Val{:claude_code}, credential::Dict{String,Any}, model::AbstractString,
        messages::Vector{OllamaMessage}; temperature::Real=0.2, maxTokens::Integer=4096,
        onThinking=nothing, jsonMode::Bool=false, timeoutS::Real=120.0)::String
    get(credential, "mode", nothing) == "claude-code" || error("Invalid Claude Code credential mode")
    isempty(strip(model)) && error("Claude Code model is empty")
    all(c -> isascii(c) && !isspace(c) && !iscntrl(c), model) || error("Invalid Claude Code model")
    maxTokens > 0 || error("Claude Code maxTokens must be positive")
    context = claudeCodeInput(messages)
    args = ["--safe-mode", "--print", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--permission-mode", "dontAsk", "--permission-prompts", "none", "--no-session-persistence",
        "--disable-slash-commands", "--no-chrome", "--model", String(model)]
    isempty(context.system) || append!(args, ["--system-prompt", context.system])
    # Output budget is an official CLI control; temperature is CLI-managed.
    environment = ["CLAUDE_CODE_MAX_OUTPUT_TOKENS" => string(maxTokens),
        "CLAUDE_CODE_DISABLE_ATTACHMENTS" => "1", "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE" => "0"]
    result = claudeCodeRun(args, context.input; timeoutS, environment)
    result.exitcode == 0 || error("Claude Code inference process failed")
    return claudeCodeCompletion(result.stdout; onThinking)
end
