using Flooty
using Flooty: activateReplTool!, activeReplSession, deactivateReplTool!
import FlootyAbstract
import FlootyPTYLayer

fail = 0
function check(name, cond)
    global fail
    if cond; println("PASS: ", name)
    else; println("FAIL: ", name); fail += 1; end
end

# --- (1) happy path: executing "2 + 2" succeeds and output contains "4" ---
# Activation must lazy-load the genuine integration before the test imports it.
sess = activateReplTool!()
import FlootySessions
check("activate returns ReplSession", sess isa FlootyPTYLayer.ReplSession)
check("activeReplSession matches", activeReplSession() === sess)
check("REPL_EXECUTOR installed", FlootySessions.REPL_EXECUTOR[] !== nothing)

executor = FlootySessions.REPL_EXECUTOR[]
ok, out = executor("echo \$((2 + 2))")
check("2+2 ok", ok === true)
check("2+2 output contains 4", occursin("4", out))

# --- route through the actual FlootySessions tool handler ---
toolResult = FlootyAbstract.execute_tool("repl", Dict{String,Any}("code" => "echo \$((1 + 2))"))
check("tool handler repl ok", toolResult.success)
check("tool handler output contains 3", occursin("3", toolResult.data))

# --- (2) failure path: undefined function returns false with ERROR text ---
ok2, err = executor("nosuchfunc")
check("nosuchfunc fails", ok2 === false)
check("nosuchfunc error contains ERROR:", occursin("ERROR:", err))

toolResult2 = FlootyAbstract.execute_tool("repl", Dict{String,Any}("code" => "nosuchfunc"))
check("tool handler reports failure", !toolResult2.success)
check("tool handler carries error text",
      occursin("ERROR:", toolResult2.error))

# --- state survives across evals in the same REPL process ---
executor("ptyStateVar=\$((41 + 1))")
ok3, out3 = executor("echo \$((ptyStateVar * 2))")
check("state persists across evals", ok3 && occursin("84", out3))

# --- sidecar written from the live session ---
sidecarPath = FlootyPTYLayer.writeStatusSidecar!(sess)
check("sidecar exists", isfile(sidecarPath))
check("sidecar has status table", occursin("| eval |", read(sidecarPath, String)))

# --- re-activation replaces the session (old one closed first) ---
oldSess = activeReplSession()
sess2 = activateReplTool!()
check("reactivation returns new session", sess2 !== oldSess)
check("old session closed", oldSess.closed)
check("active session updated", activeReplSession() === sess2)
executor2 = FlootySessions.REPL_EXECUTOR[]
ok4, out4 = executor2("echo \$((5 + 5))")
check("new session executes", ok4 && occursin("10", out4))

# --- (3) deactivation closes the session and resets the executor ---
deactivateReplTool!()
check("deactivate resets session ref", activeReplSession() === nothing)
check("deactivate resets REPL_EXECUTOR", FlootySessions.REPL_EXECUTOR[] === nothing)
check("session closed after deactivate", sess2.closed)

# idempotent second call must not throw
deactivateReplTool!()
check("deactivate idempotent", activeReplSession() === nothing &&
                               FlootySessions.REPL_EXECUTOR[] === nothing)

println(fail == 0 ? "ALL PASS" : "FAILURES: $fail")
exit(fail == 0 ? 0 : 1)
