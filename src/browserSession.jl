# browserSession.jl — a first-class BROWSER session.
#
# The page owns the panel (URL bar + iframe). The driver is a chat-like loop that
# can NAVIGATE the panel or answer; cross-origin pages are not readable, so
# navigation is the action surface (a CDP-backed reader can be layered later).

const BROWSER_COMPLETE = Ref{Union{Nothing,Function}}(nothing)

const BROWSER_SYSTEM_PROMPT = """
You drive a BROWSER SESSION: a live web panel the user can see. You know the
current URL and the conversation, but NOT the cross-origin page DOM.
Reply with EXACTLY ONE JSON object and nothing else:
{"action":"navigate","url":"https://..."}   open a URL in the panel
{"action":"reply","text":"<answer>"}        answer the user
{"action":"done","summary":"<what happened>"}
Prefer search/result URLs the user can read; be concise. Never claim to have
read content the panel cannot expose.
"""

function parseBrowserReply(reply::AbstractString)
    raw = stripThinking(String(reply))
    act = extractActionJson(raw)
    if act === nothing
        try
            obj = JSON3.read(strip(raw))
            obj isa JSON3.Object && (act = obj)
        catch
        end
    end
    if act !== nothing
        kind = lowercase(getstr(act, "action", ""))
        if kind == "navigate"
            return (kind = :navigate, url = String(getstr(act, "url", "")),
                    text = String(getstr(act, "reply", "")))
        end
        body = String(getstr(act, "reply", getstr(act, "text", getstr(act, "summary", ""))))
        return (kind = :chat, url = "", text = body)
    end
    return (kind = :chat, url = "", text = String(strip(stripProviderMarkup(raw))))
end

"Create a BrowserSession (child of `parent_id`, or the root chat when empty)."
function launchBrowserSession!(parent_id::AbstractString = "";
                               url::AbstractString = "about:blank",
                               name::AbstractString = "browser")
    root = ensureRootChatSession!()
    parent = isempty(parent_id) ? nothing : sessionForId(parent_id)
    sess = registerSession!(BrowserSession(
        parent = parent === nothing ? nothing : parent.id,
        url = String(url)))
    if parent isa ChatSession || parent isa TerminalSession || parent isa BrowserSession
        push!(parent.children, sess.id)
    end
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    if wv !== nothing
        FlootyPTYLayer.addBrowserTabUi(
            wv, sess.id, String(name), String(url);
            root_id = root.id, parent_id = parent === nothing ? "" : parent.id)
        @async begin
            sleep(0.4)
            try
                FlootyPTYLayer.pushAgentEventToWindow(wv,
                    AgentMonitorThinkingEvent(sess.id,
                        "browser monitor attached — watching navigation"))
            catch
            end
        end
    end
    return sess
end

"The UI chooser's browser spawner."
newBrowserSessionHandler(parent_id::AbstractString, url::AbstractString,
                         name::AbstractString) =
    launchBrowserSession!(parent_id; url = isempty(url) ? "about:blank" : url,
                          name = isempty(name) ? "browser" : name)

"The page's URL bar: keep the session's current URL in sync."
function browserNavigateHandler(session_id::AbstractString, url::AbstractString)
    s = sessionForId(session_id)
    s isa BrowserSession || return false
    s.url = String(url)
    return true
end

"Drive one browser turn: navigate or reply, in the session's chat rail."
function browserTurnFor!(sess::BrowserSession, wv, text::AbstractString,
                         tab::AbstractString = "")
    startTrajectoryMonitor!(sess)
    trajectoryTask!(sess, text)
    noteUserMessage!(sess, text)
    conv = conversationFor(sess.id)
    recordTask!(conv, text)
    cfg = sessionModelConfig(sess)
    conv.model = cfg.actorModel
    setSessionStatus!(sess, "thinking")
    @async begin
        try
            fn = BROWSER_COMPLETE[]
            if fn === nothing
                fn = makeCompleteFn(cfg, cfg.actorModel;
                    onThinking = chunk -> (wv === nothing ? nothing :
                        pushAgentEventToWindow(wv,
                            AgentThinkingEvent(sess.id, String(chunk)))))
            end
            msgs = OllamaMessage[OllamaMessage(role = "system",
                content = BROWSER_SYSTEM_PROMPT * "\nCURRENT URL: " * sess.url)]
            for n in takeParentNotes!(sess.id)
                push!(msgs, OllamaMessage(role = "user", content = "STEER: " * n))
            end
            append!(msgs, conversationContext(conv))
            push!(msgs, OllamaMessage(role = "user", content = "TASK: " * text))
            ctxLimit = try
                contextLengthFor(cfg.actorModel)
            catch
                0
            end
            ctxUse = contextUsage(msgs; limit = ctxLimit)
            try
                trajectoryContext!(sess, ctxUse.tokens, ctxUse.limit)
            catch
            end
            wv === nothing || pushAgentEventToWindow(wv,
                AgentContextUsageEvent(sess.id, ctxUse.tokens, ctxUse.limit))
            wv === nothing || pushAgentEventToWindow(
                wv, AgentProgressEvent(sess.id, "thinking…"))
            reply = fn(msgs)
            thinking = extractThinking(reply)
            if !isempty(strip(thinking))
                pushAgentEventToWindow(wv, AgentThinkingEvent(sess.id, strip(thinking)))
            end
            parsed = parseBrowserReply(reply)
            if parsed.kind === :navigate && !isempty(strip(parsed.url))
                url = strip(parsed.url)
                if !startswith(url, "http://") && !startswith(url, "https://") &&
                   !startswith(url, "about:")
                    url = "https://" * url
                end
                sess.url = url
                if wv !== nothing
                    pushAgentEventToWindow(
                        wv, AgentBrowserNavigateEvent(sess.id, url))
                    pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                        sess.id, "navigated to " * url))
                end
                shown = "Opening " * url
            else
                shown = strip(parsed.text)
            end
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            isempty(shown) && (shown = "The browser returned no answer.")
            ev = AgentTextEvent(sess.id, shown)
            recordAgentEvent!(conv, ev)
            wv === nothing || pushAgentEventToWindow(wv, ev)
            setSessionStatus!(sess, "idle")
        catch err
            setSessionStatus!(sess, "error")
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            wv === nothing || pushAgentEventToWindow(wv,
                AgentStatusEvent(sess.id, "browser failed: " * sprint(showerror, err),
                                 :error))
        end
        return nothing
    end
    return true
end
