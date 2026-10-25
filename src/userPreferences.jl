# userPreferences.jl — durable, user-editable preferences.
#
# The USER monitor watches live intent; this learner only sees explicit user
# submissions and writes durable statements to ~/.flooty/preferences.md (or
# FLOOTY_PREFERENCES_PATH). It never reads terminal output or drafts.

const PREFERENCE_COMPLETE = Ref{Union{Nothing,Function}}(nothing)
const PREFERENCE_LOCKS = IdDict{Any,ReentrantLock}()
const PREFERENCE_LOCKS_LOCK = ReentrantLock()
const PREFERENCE_ANNOUNCED = IdDict{Any,Bool}()

function preferenceUiId(sess)::String
    if sess isa ReplSession
        parent = try
            splitParentSession(sess)
        catch
            nothing
        end
        parent === nothing || return sessionIdFor(parent)
        return sessionIdFor(sess)
    end
    return try
        String(sess.id)
    catch
        ""
    end
end

function preferenceEvent!(sess, text::AbstractString)
    wv = activeTerminalUiWebview()
    wv === nothing && return nothing
    pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
        preferenceUiId(sess), String(text); monitor = :preferences))
    return nothing
end

function announcePreferences!(sess)
    lock(PREFERENCE_LOCKS_LOCK) do
        get!(PREFERENCE_ANNOUNCED, sess, false) && return false
        PREFERENCE_ANNOUNCED[sess] = true
        return true
    end || return false
    preferenceEvent!(sess, "preferences monitor attached — learning explicit preferences")
    return true
end

preferencesPath() = begin
    override = get(ENV, "FLOOTY_PREFERENCES_PATH", "")
    isempty(override) ? joinpath(homedir(), ".flooty", "preferences.md") :
                        String(override)
end

function preferenceProjectName()::String
    project = try
        String(Base.active_project())
    catch
        ""
    end
    isempty(project) ? basename(pwd()) : basename(dirname(project))
end

function looksLikePreference(text::AbstractString)::Bool
    re = r"(?i)\b(always|never|prefer|prefers|from now on|remember|don't|do not|avoid|instead|i like|i want you to)\b"
    return occursin(re, text)
end

"Read/write one scope's bullet; dedupe is case-insensitive across the file."
function recordUserPreference!(scope::AbstractString, text::AbstractString;
                               project::AbstractString = preferenceProjectName(),
                               source::AbstractString = "user")::Bool
    pref = strip(replace(String(text), r"\s+" => " "))
    (isempty(pref) || length(pref) > 400) && return false
    sc = lowercase(String(scope)) == "global" ? "global" : "project"
    path = preferencesPath()
    mkpath(dirname(path))
    lock(PREFERENCE_LOCKS_LOCK) do
        lines = isfile(path) ? readlines(path) : String[]
        isempty(lines) && append!(lines, ["# User preferences", ""])
        bullets = [strip(replace(replace(l, r"^- " => ""),
                                 r"\s*\(source: [^)]*\)$" => ""))
                   for l in lines if startswith(strip(l), "- ")]
        any(lowercase(b) == lowercase(pref) for b in bullets) && return false
        header = sc == "global" ? "## Global" : "## Project: " * String(project)
        idx = findfirst(l -> strip(l) == header, lines)
        if idx === nothing
            isempty(lines) || (isempty(strip(lines[end])) || push!(lines, ""))
            push!(lines, header, "")
            idx = length(lines) - 1
        end
        # Insert at the end of this section, before the next header.
        insert_at = idx + 1
        j = idx + 1
        while j <= length(lines) && !startswith(strip(lines[j]), "## ")
            insert_at = j + 1
            j += 1
        end
        source_note = isempty(source) ? "" : " (source: " * String(source) * ")"
        insert!(lines, insert_at, "- " * pref * source_note)
        tmp = path * ".tmp." * string(getpid())
        open(tmp, "w") do io
            for l in lines
                println(io, l)
            end
        end
        mv(tmp, path; force = true)
        return true
    end
end

"Known preferences as prompt-ready text (global + this project)."
function preferencesContext(; project::AbstractString = preferenceProjectName())::String
    path = preferencesPath()
    isfile(path) || return ""
    lines = readlines(path)
    out = String[]
    active = false
    for l in lines
        s = strip(l)
        if startswith(s, "## Global") || s == "## Project: " * String(project)
            active = true
            push!(out, s)
            continue
        elseif startswith(s, "## ")
            active = false
        elseif active && startswith(s, "- ")
            push!(out, s)
        end
    end
    return isempty(out) ? "" : join(out, "\n") * "\n"
end

function learnPreferences!(sess, text::AbstractString)
    key = sess
    lk = lock(PREFERENCE_LOCKS_LOCK) do
        get!(PREFERENCE_LOCKS, key) do
            ReentrantLock()
        end
    end
    lock(lk) do
        fn = PREFERENCE_COMPLETE[]
        fn === nothing && (fn = monitorCompleteFn(sessionModelConfig(sess)))
        reply = try
            fn(OllamaMessage[
                OllamaMessage(role = "system", content = """
Extract only DURABLE user preferences explicitly stated below. Never infer a
preference from a command, question, or one-off task. Return exactly:
{"preferences":[{"scope":"global"|"project","text":"..."}]}
Use global only for cross-project style/workflow preferences; otherwise project.
Return an empty list when nothing durable was stated. Do not restate the message.
"""),
                OllamaMessage(role = "user", content = String(text)),
            ])
        catch err
            @debug "preference learner failed" exception = err
            try
                preferenceEvent!(sess, "preferences monitor error — " *
                    first(sprint(showerror, err), 160))
            catch
            end
            return nothing
        end
        raw = strip(stripThinking(reply))
        dec = try
            JSON3.read(raw)
        catch
            mt = match(r"\{.*\}s", raw)
            mt === nothing ? nothing : try JSON3.read(mt.match) catch; nothing end
        end
        dec isa JSON3.Object || begin
            preferenceEvent!(sess, "observe — no structured preference")
            return nothing
        end
        prefs = get(dec, "preferences", nothing)
        prefs isa AbstractVector || return nothing
        isempty(prefs) && preferenceEvent!(sess, "observe — no durable preference")
        for p in prefs
            p isa AbstractDict || continue
            body = strip(String(get(p, "text", "")))
            isempty(body) && continue
            scope = lowercase(String(get(p, "scope", "project")))
            recordUserPreference!(scope, body; source = "user") || continue
            preferenceEvent!(sess, "preference noted — " * first(body, 160))
        end
        return nothing
    end
    return nothing
end

"""
    noteUserMessage!(sess, text)

Called only for a SUBMITTED user message. Heuristic gate keeps ordinary task
instructions from paying for a model call; the learner still decides whether
anything is durable.
"""
function noteUserMessage!(sess, text::AbstractString)
    candidate = strip(String(text))
    length(candidate) < 8 && return false
    looksLikePreference(candidate) || return false
    announcePreferences!(sess)
    @async learnPreferences!(sess, candidate)
    return true
end
