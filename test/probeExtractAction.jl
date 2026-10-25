using Flooty
import JSON3

# extractActionJson must find the action object even when the model wraps it
# in prose that itself contains brace characters (the exact failure shape seen
# in probeAgentRunner: “{INTENT_42} …” ahead of the real JSON payload).

function assertCond(cond::Bool, label::AbstractString)
    cond || (println("FAIL[$label]"); exit(1))
end

# 1. Prose containing a non-JSON brace pair BEFORE the true payload.
r = Flooty.extractActionJson(
    "The output {INTENT_42} confirms completion. {\"action\":\"done\",\"summary\":\"printed\"}")
assertCond(r !== nothing && String(r[:action]) == "done", "prose-brace-before-json")

# 2. Clean single-object replies still work.
r = Flooty.extractActionJson(
    "{\"action\":\"send\",\"code\":\"println(1+1)\"}")
assertCond(r isa JSON3.Object && String(r[:action]) == "send", "clean-json")

# 3. Markdown-fenced JSON.
r = Flooty.extractActionJson(
    "```json\n{\"action\":\"wait\",\"seconds\":2}\n```")
assertCond(r !== nothing && String(r[:action]) == "wait", "fenced-json")

# 4. Truncated JSON (no closing brace) → nothing, never a hang.
r = Flooty.extractActionJson("{\"action\":\"done\", \"summary\":\"x")
assertCond(r === nothing, "truncated")

# 5. No JSON at all → nothing.
assertCond(Flooty.extractActionJson("I think the task is complete.") === nothing,
           "no-json")

# 6. The exact granite4 done shape seen live in probeAgentRunner: bare JSON
#    whose summary carries ESCAPED quotes around INTENT_42.
r = Flooty.extractActionJson(
    "{\"action\":\"done\",\"summary\":\"Printed \\\"INTENT_42\\\" after setting x = 21\"}")
assertCond(r !== nothing && String(r[:action]) == "done", "done-escaped-quotes")

# 7. Literal RAW newline inside a string value — invalid JSON strictly, but
#    the extractor must still recover the action instead of giving up.
r = Flooty.extractActionJson(
    "{\"action\":\"done\",\"summary\":\"printed\nINTENT_42\"}")
assertCond(r !== nothing && String(r[:action]) == "done", "raw-newline-in-string")

# 8. CRLF line endings around/inside the payload.
r = Flooty.extractActionJson(
    "{\"action\":\"wait\",\r\n\"seconds\":2}\r\n")
assertCond(r !== nothing && String(r[:action]) == "wait", "crlf-json")

# 9. Smart quotes decorating the object (model “beautified” its reply).
r = Flooty.extractActionJson(
    "\u201c{\"action\":\"done\",\"summary\":\"ok\"}\u201d")
assertCond(r !== nothing && String(r[:action]) == "done", "smart-quoted")

# 10. Escaped quotes INSIDE a code value wrapped in chatter on both sides.
r = Flooty.extractActionJson(
    "Sure! {\"action\":\"send\",\"code\":\"println(\\\"hi\\\")\"} hope this helps")
assertCond(r !== nothing && String(r[:action]) == "send", "chatter-code-escapes")

# 11. THE LIVE FAILURE (probeAgentRunner session, granite4): RAW unescaped
#     quotes around CUDA inside the feedback body — string ends early.
cudaReply = "{\"action\":\"feedback\",\"title\":\"Package Issue\"," *
            "\"body\":\"The CUDA package is not installed. Please run " *
            "`import Pkg; Pkg.add(\"CUDA\")` to install it before proceeding." *
            "with the Fibonacci function.\"}"
r = Flooty.extractActionJson(cudaReply)
assertCond(r !== nothing && String(r[:action]) == "feedback", "live-cuda-feedback")
assertCond(occursin("Pkg.add(\"CUDA\")", String(r[:body])), "live-cuda-body-intact")

# 12. Raw quotes in a SEND code value with the ambiguous `", ` shape.
r = Flooty.extractActionJson(
    "{\"action\":\"send\",\"code\":\"println(\"hello\", 42)\"}")
assertCond(r !== nothing && String(r[:action]) == "send", "raw-quote-code-comma")
assertCond(String(r[:code]) == "println(\"hello\", 42)", "raw-quote-code-value")

# 13. Inner quote before `, "key":` MUST still be treated as a closer
#     (multi-key object whose first value carries raw quotes).
r = Flooty.extractActionJson(
    "{\"action\":\"feedback\",\"title\":\"note: x = f(\"y\")\",\"kind\":\"warn\",\"body\":\"b\"}")
assertCond(r !== nothing && String(r[:action]) == "feedback" &&
           String(r[:kind]) == "warn", "inner-quote-multi-key")

# 14. THE LIVE SSH FAILURE: a grep code value with RAW inner quotes AND raw
#     regex alternation (`\|`, invalid JSON escapes). Both repairs are needed.
grepReply = "{\"action\":\"send\",\"code\":\"grep -rn \"ALPHA_LO\\|" *
            "ALPHA_HI\\|T_FLOOR\\|LOG_FLOOR\\|CARRY_CLIP\" src/\"}"
r = Flooty.extractActionJson(grepReply)
assertCond(r !== nothing && String(r[:action]) == "send", "raw-quote-grep")
assertCond(occursin("ALPHA_LO", String(r[:code])) &&
           occursin("src/", String(r[:code])), "raw-quote-grep-code")

# 15. Lazy JSON3 strings inside nested objects/arrays must still reach repair.
r = Flooty.extractActionJson(
    "{\"action\":\"done\",\"meta\":{\"steps\":[{\"keys\":\"\\x11\"}]}}")
assertCond(r isa JSON3.Object && String(r[:meta][:steps][1][:keys]) == "\x11",
           "nested-invalid-escape-repaired")
r = Flooty.extractActionJson(
    "{\"action\":\"done\",\"meta\":{\"steps\":[{\"keys\":\"\\uZZZZ\"}]}}")
assertCond(r === nothing, "nested-invalid-unicode-rejected")

println("EXTRACT_ACTION_PROBE_OK")
