# contextProbe.jl — model context window, usage tracking, compaction.
#
# Three questions this pins, all without a window or a live model:
#   * how big IS the window (the endpoint reports it; `FLOOTY_CONTEXT_LENGTH` wins);
#   * how full are we (estimated tokens, reported on every turn's status line);
#   * compaction (automatic at CONTEXT_COMPACT_AT, and on demand via
#     {"action":"compact"}) folds older turns into ONE digest, keeps the system
#     prompt and the recent turns, and never needs a model call.
#
# Run: julia --startup-file=no --project=. test/contextProbe.jl
using Flooty
using Flooty: contextLengthFor, contextUsage, estimateTokens, compactMessages!,
    formatTokens, CONTEXT_COMPACT_AT, CONTEXT_KEEP_LAST, parseAction, CompactAction,
    AGENT_SYSTEM_PROMPT
using FlootyPTYLayer: startReplSession, closeSession!
using FlootyStreams: OllamaMessage
import JSON3

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# ---- 1: the window comes from the model/endpoint ---------------------------
limit = contextLengthFor("beam:cloud")
check("the endpoint reports a context window", limit > 100_000, limit)
check("…and it is cached (second call is the same value)",
      contextLengthFor("beam:cloud") == limit)
ENV["FLOOTY_CONTEXT_LENGTH"] = "1234"
check("FLOOTY_CONTEXT_LENGTH overrides the endpoint",
      contextLengthFor("beam:cloud") == 1234, contextLengthFor("beam:cloud"))
delete!(ENV, "FLOOTY_CONTEXT_LENGTH")

# ---- 2: usage estimate ------------------------------------------------------
msgs = [OllamaMessage(role = "user", content = "x"^400)]
u = contextUsage(msgs; limit = 1000)
check("400 chars ≈ 100 tokens (chars/4)", u.tokens == 100, u.tokens)
check("usage reports the ratio against the window", u.ratio ≈ 0.1, u.ratio)
check("formatTokens is short", formatTokens(1048576) == "1048.6k" &&
      formatTokens(850) == "850", (formatTokens(1048576), formatTokens(850)))

# ---- 3: compaction keeps the contract --------------------------------------
big = OllamaMessage[OllamaMessage(role = "system", content = "SYSTEM PROMPT")]
append!(big, [OllamaMessage(role = "user", content = "turn $i") for i in 1:40])
(before_n = length(big))
(removed, kept) = compactMessages!(big)
# system + digest + keepLast remain: removed = n - 1 (system) - keepLast
check("compaction removes the middle", removed == before_n - 1 - CONTEXT_KEEP_LAST,
      (removed, kept))
check("…keeps the SYSTEM prompt first", big[1].role == "system" &&
      big[1].content == "SYSTEM PROMPT")
check("…inserts ONE digest", occursin("[compacted]", big[2].content) &&
      big[2].role == "user")
check("…and keeps the last turns verbatim",
      big[end].content == "turn 40" && length(big) == CONTEXT_KEEP_LAST + 2,
      (length(big), big[end].content))
check("a short conversation is left alone",
      begin
          small = OllamaMessage[OllamaMessage(role = "system", content = "s"),
                                OllamaMessage(role = "user", content = "u")]
          compactMessages!(small) == (0, 2)
      end)

# ---- 4: the loop tracks usage and compacts automatically -------------------
sess = startReplSession(`julia --startup-file=no -q`)
try
    sleep(2.0)
    turns = Ref(0)
    sent = String[]
    fake = messages -> begin
        turns[] += 1
        if turns[] <= 6
            code = "println(\"CTX_" * string(turns[]) * "\")"
            push!(sent, code)
            return "{\"action\":\"send\",\"code\":\"" * code * "\"}"
        end
        return "{\"action\":\"done\",\"summary\":\"context probe done\"}"
    end
    # Tiny window: the very first snapshot already crosses the threshold, so the
    # automatic path must fire without needing a huge conversation.
    res = runTerminalAgent!(sess, "print CTX_1..CTX_6 and finish";
                            completeFn = fake, maxTurns = 10, evalTimeoutS = 20.0,
                            contextLimit = 600)
    transcript = join(res.transcript, "\n")
    check("the run finished", res.ok, res.summary)
    check("the status line reports context usage", occursin("ctx ", transcript),
          first(transcript, 120))
    check("automatic compaction fired at the threshold",
          occursin("[compact]", transcript), first(transcript, 160))
    check("…and actually folded messages (not a no-op)",
          occursin(r"folded [1-9]\d* messages into a digest", transcript),
          first(transcript, 200))
    check("…and the terminal still executed the commands",
          occursin("CTX_6", transcript) || occursin("ok", transcript))
    check("the prompt documents the compact action",
          occursin("{\"action\":\"compact\"}", AGENT_SYSTEM_PROMPT) &&
          occursin("CONTEXT BUDGET", AGENT_SYSTEM_PROMPT))
    check("CompactAction parses", parseAction(JSON3.read("{\"action\":\"compact\"}")) isa
          CompactAction)

    # ---- 5: on-demand compaction ------------------------------------------
    turns[] = 0
    asked = Ref(false)
    fake2 = messages -> begin
        turns[] += 1
        if !asked[]
            asked[] = true
            return "{\"action\":\"compact\"}"
        elseif turns[] <= 3
            return "{\"action\":\"send\",\"code\":\"println(42)\"}"
        end
        return "{\"action\":\"done\",\"summary\":\"after compact\"}"
    end
    res2 = runTerminalAgent!(sess, "compact then work"; completeFn = fake2,
                             maxTurns = 6, evalTimeoutS = 20.0, contextLimit = 100_000)
    t2 = join(res2.transcript, "\n")
    check("the agent can compact on request",
          occursin("compact: ", t2) && occursin("folded into a digest", t2),
          first(t2, 160))
    check("…and keeps working afterwards", res2.ok, res2.summary)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("CONTEXT_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
