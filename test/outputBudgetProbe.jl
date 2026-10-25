# outputBudgetProbe.jl — thinking models get an explicit completion budget.
using Flooty
using Flooty: chatCompletion, OllamaMessage
using Sockets
using JSON3

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

check("the config carries a 4096-token default",
      Flooty.defaultAgentModelConfig().maxOutputTokens == 4096)

server = Sockets.listen(ip"127.0.0.1", 0)
port = Sockets.getsockname(server)[2]
bodySeen = Ref("")
stopServer = Ref(false)
@async while !stopServer[]
    sock = try accept(server) catch; break end
    @async try
        readline(sock)
        len = 0
        while true
            l = readline(sock)
            isempty(strip(l)) && break
            m = match(r"^Content-Length:\s*(\d+)"i, l)
            m === nothing || (len = parse(Int, m.captures[1]))
        end
        bodySeen[] = String(read(sock, len))
        payload = JSON3.write(Dict("choices" => [Dict("message" => Dict("role" => "assistant",
                                                                     "content" => "OK"))]))
        write(sock, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" *
                    "Content-Length: $(sizeof(payload))\r\n\r\n" * payload)
        flush(sock)
    catch
    finally
        try close(sock) catch end
    end
end

try
    reply = chatCompletion("http://127.0.0.1:$port/v1", "fake", [OllamaMessage(role="user", content="hi")];
                           maxTokens=1234, timeoutS=5.0)
    check("the completion succeeds", reply == "OK", reply)
    body = JSON3.read(bodySeen[])
    check("the request carries max_tokens=1234", get(body, "max_tokens", nothing) == 1234,
          bodySeen[])
finally
    stopServer[] = true
    try close(server) catch end
end
println()
if isempty(failures)
    println("OUTPUT_BUDGET_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
