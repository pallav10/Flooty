# wireMessageProbe.jl — the OpenAI-compatible request must never carry a message
# without a `content` STRING.
#
# Reported symptom: "I am handed over immediately after prompt" — submitting an
# assist instruction flipped ownership to the agent and back within a few
# seconds without the agent doing any work.
#
# Cause (reproduced against the live endpoint): a reply that is ONLY provider
# reasoning strips to empty content (`stripThinking`), and
# `StructTypes.omitempties(::Type{OllamaMessage})` then DROPS the `content`
# field when JSON serializes the message list. The endpoint reads a nil content
# and answers
#
#     400 invalid message content type: <nil>
#
# which the loop reports as "[error] LLM call failed", ends the run, and the
# standing runner hands the REPL back to the user.
#
# `requestMessages` is the guard: content is always a string, reasoning and the
# internal `_type` tag never go on the wire, tool-call bookkeeping survives.
#
# Run: julia --startup-file=no --project=. test/wireMessageProbe.jl
import Flooty
using JSON3
import FlootyStreams
using FlootyStreams: OllamaMessage

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = isempty(detail) ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

conv = OllamaMessage[
    OllamaMessage(role = "system", content = "sys"),
    OllamaMessage(role = "user", content = "TASK: print 1 and stop"),
    # The turn that used to break the next request: reasoning only.
    OllamaMessage(role = "assistant", content = nothing, thinking = "nothing to observe"),
    # stripThinking(reply) of an all-reasoning reply is "" — same trap.
    OllamaMessage(role = "assistant", content = ""),
    OllamaMessage(role = "user", content = "SYSTEM NOTE: send the action JSON"),
    OllamaMessage(role = "assistant", content = "{\"action\":\"done\",\"summary\":\"ok\"}",
                  tool_calls = nothing),
]

wire = Flooty.requestMessages(conv)

check("one wire message per conversation message", length(wire) == length(conv),
      length(wire))
check("every wire message carries a String content",
      all(m -> haskey(m, "content") && m["content"] isa String, wire),
      [get(m, "content", "<absent>") for m in wire])
check("an all-reasoning assistant turn becomes empty content, not a missing field",
      wire[3]["content"] == "" && wire[4]["content"] == "")
check("reasoning travels in its OWN field, never as prose in content",
      wire[3]["reasoning"] == "nothing to observe" && wire[3]["content"] == "" &&
      !occursin("nothing to observe", wire[3]["content"]),
      wire[3])
check("an empty-field name DISABLES reasoning on the wire",
      all(m -> !haskey(m, "reasoning"), Flooty.requestMessages(conv;
          reasoningField = "")))
check("the reasoning field name is configurable (provider dialects)",
      haskey(Flooty.requestMessages(conv; reasoningField = "reasoning_content")[3],
             "reasoning_content") &&
      haskey(Flooty.requestMessages(conv; reasoningField = "thinking")[3],
             "thinking"))
check("the configured field is part of AgentModelConfig",
      Flooty.defaultAgentModelConfig().reasoningField == "reasoning")
check("the internal _type tag never goes on the wire",
      all(m -> !haskey(m, "_type"), wire))
check("roles are preserved",
      [m["role"] for m in wire] ==
      ["system", "user", "assistant", "assistant", "user", "assistant"])

# tool-call bookkeeping must survive (native tool-call turns round-trip).
call = FlootyStreams.OllamaToolCall(
    FlootyStreams.OllamaToolCallFunction("repl", Dict{String,Any}("code" => "1+1")),
    "call_1")
withCall = Flooty.requestMessages(OllamaMessage[
    OllamaMessage(role = "assistant", content = nothing, tool_calls = [call]),
    OllamaMessage(role = "tool", content = "2", tool_name = "repl",
                  tool_call_id = "call_1"),
])
check("tool_calls survive the wire form",
      haskey(withCall[1], "tool_calls") && length(withCall[1]["tool_calls"]) == 1)
check("tool_name/tool_call_id survive the wire form",
      withCall[2]["tool_name"] == "repl" && withCall[2]["tool_call_id"] == "call_1")

# The body the endpoint actually receives.
body = JSON3.write(Dict("model" => "m", "messages" => wire, "stream" => false))
parsed = JSON3.read(body)
check("serialized body has a content key on every message",
      all(m -> haskey(m, :content) && m.content !== nothing, parsed.messages),
      [m for m in parsed.messages if !haskey(m, :content)])
check("serialized body never contains a null content",
      !occursin("\"content\":null", body))

println(isempty(failures) ? "WIRE_MESSAGE_PROBE_PASSED" :
            "WIRE_MESSAGE_PROBE_FAILED " * join(failures, ", "))
exit(isempty(failures) ? 0 : 1)
