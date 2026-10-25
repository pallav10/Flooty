# thinkingStreamProbe.jl — THINKING streams while the model is still generating.
#
# Before: the one-shot client returned the whole reply (reasoning folded into
# <thinking>) after the model finished, so a long reasoning turn looked frozen.
# Now `streamCompletion` reads the stream and calls `onThinking(chunk)` per
# reasoning delta; the loop coalesces those into live AgentThinkingEvents and
# still records the FULL thinking once at the end of the turn.
#
# The frame reader is a pure function, so this probe proves the streaming
# behaviour without depending on how a particular model chunks its output:
# (the configured `beam:cloud` currently emits its deltas in ONE burst — measured
# — so timing assertions here are about the READER, not the endpoint.)
#
# Run: julia --startup-file=no --project=. test/thinkingStreamProbe.jl
using Flooty
using Flooty: consumeSSEFrames, streamCompletion, makeCompleteFn, AgentModelConfig,
    AgentThinkingEvent, streamThinking!, flushThinking!, LoopContext
using FlootyPTYLayer: startReplSession, closeSession!
using FlootyStreams: OllamaMessage
import JSON3

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sseFrame(delta) = "data: " * JSON3.write(Dict("choices" => [Dict("delta" => delta)])) * "\n"

# ---- 1: every reasoning delta reaches the sink, in order, content separate ---
body = IOBuffer(join([
    sseFrame(Dict("reasoning" => "step ONE ")),
    sseFrame(Dict("content" => "")),
    sseFrame(Dict("reasoning_content" => "step TWO ")),
    sseFrame(Dict("content" => "answer ")),
    sseFrame(Dict("content" => "42")),
    "data: [DONE]\n",
], ""))
chunks = String[]
content = IOBuffer()
reasoning = IOBuffer()
seen = consumeSSEFrames(body, c -> push!(chunks, String(c));
                        content = content, reasoning = reasoning)
check("SSE frames are consumed", seen)
check("one sink call per reasoning delta, in order",
      chunks == ["step ONE ", "step TWO "], chunks)
contentText = String(take!(content))
reasoningText = String(take!(reasoning))
check("dialect fields are both honoured (reasoning, reasoning_content)",
      occursin("step ONE", reasoningText) && occursin("step TWO", reasoningText),
      reasoningText)
check("content is kept out of the reasoning", contentText == "answer 42", contentText)
check("a delta is never counted twice (field dedupe)",
      reasoningText == "step ONE step TWO ", reasoningText)

# ---- 2: a non-SSE body reports "no frames" so the caller can fall back -------
plain = IOBuffer(JSON3.write(Dict("choices" => [Dict("message" =>
    Dict("role" => "assistant", "content" => "one shot"))])))
got = String[]
check("a plain JSON body is not mistaken for a stream",
      consumeSSEFrames(plain, c -> push!(got, String(c))) == false && isempty(got))

# ---- 3: the loop coalesces streamed thinking and flushes the tail -----------
sess = startReplSession(`julia --startup-file=no -q`)
try
    sleep(2.0)
    ctx = LoopContext(sess = sess, task = "", conv = conversationFor(sess),
                      completeFn = nothing, onEvent = _ -> nothing,
                      evalTimeoutS = 10.0, waitTimeoutS = 10.0,
                      result = Flooty.AgentLoopResult(),
                      messages = OllamaMessage[])
    streamThinking!(ctx, "first ")
    check("the FIRST chunk is pushed immediately (no lag)",
          isempty(ctx.thinkingPending) && ctx.streamedThinking)
    streamThinking!(ctx, "second ")
    streamThinking!(ctx, "third ")
    check("nearby chunks coalesce instead of one event per token",
          ctx.thinkingPending == "second third ", ctx.thinkingPending)
    check("flush pushes the coalesced text and empties the buffer",
          flushThinking!(ctx) > 0 && isempty(ctx.thinkingPending))
    check("a second flush is a no-op", flushThinking!(ctx) == 0)
finally
    closeSession!(sess)
end

# ---- 4: the configured endpoint answers through the streaming client --------
cfg = Flooty.defaultAgentModelConfig()
live = String[]
reply = try
    streamCompletion(cfg.baseUrl, cfg.actorModel,
                     [OllamaMessage(role = "user", content = "Reply with the single word STREAMED.")];
                     apiKey = cfg.apiKey, onThinking = c -> push!(live, String(c)))
catch err
    check("the live endpoint answered the streaming call", false, sprint(showerror, err))
    ""
end
if !isempty(reply)
    check("the live endpoint answered the streaming call", true)
    check("…and the reply is folded like the one-shot path",
          !occursin("FLOOTY", reply) && !isempty(strip(reply)), first(reply, 80))
end

println()
if isempty(failures)
    println("THINKING_STREAM_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
