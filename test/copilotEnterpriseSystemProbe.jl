# Standalone macOS system test: real WebView, bridge, PTY/agent, and HTTP provider fixture.
# Run: julia --startup-file=no --project=Flooty Flooty/test/copilotEnterpriseSystemProbe.jl
using HTTP, JSON3, Sockets
Sys.isapple() || error("This native system probe requires macOS.")
const SYSTEM_DIR = mktempdir()
ENV["FLOOTY_PREFERENCES_PATH"] = joinpath(SYSTEM_DIR, "preferences.md")
ENV["FLOOTY_THEME_CONFIG"] = joinpath(SYSTEM_DIR, "theme.conf")
ENV["FLOOTY_THEMES_DIR"] = joinpath(SYSTEM_DIR, "themes")
ENV["FLOOTY_API_KEY"] = ""
const ENTERPRISE = "company.ghe.com"
const APPROVED = Set{String}()
const DEVICE_REQUESTS = Ref(0)
const PUBLIC_COMPLETIONS = Ref(0)
const ENTERPRISE_COMPLETIONS = Ref(0)
const ENTERPRISE_REFRESHES = Ref(0)
const HOLD_PUBLIC = Ref(false)
const PUBLIC_HELD = Ref(false)
const RELEASE_PUBLIC = Ref(false)
const PASSED = Ref(false)
const FINISHED = Ref(false)
jsonReply(payload; status=200) = HTTP.Response(status, ["Content-Type"=>"application/json"], JSON3.write(payload))
modelReply(ids...) = jsonReply(Dict("data"=>[Dict("id"=>id, "capabilities"=>Dict("type"=>"chat"),
    "supported_endpoints"=>["/chat/completions"]) for id in ids]))

const FIXTURE = HTTP.serve!("127.0.0.1", 0) do req
    path = String(HTTP.URI(String(req.target)).path)
    origin = HTTP.header(req, "X-Flooty-System-Origin", "")
    auth = HTTP.header(req, "Authorization", "")
    body = String(copy(req.body))
    try
        enterpriseSecret = occursin("enterprise-", auth) || occursin("enterprise-refresh", body)
        enterpriseSecret && !(origin in ("https://" * ENTERPRISE, "https://copilot-api." * ENTERPRISE)) &&
            error("An enterprise credential crossed its tenant boundary")
        if path == "/v1/models"
            return modelReply("system-local", "system-monitor")
        elseif path == "/v1/chat/completions"
            content = JSON3.write(Dict("decision"=>"observe", "verdict"=>"continue", "note"=>"",
                "advice"=>"", "preferences"=>[], "reply"=>"System monitor idle"))
            return jsonReply(Dict("choices"=>[Dict("message"=>Dict("content"=>content))]))
        elseif path in ("/login/device/code", "/login/oauth/access_token")
            domain = origin == "https://github.com" ? "github.com" : origin == "https://" * ENTERPRISE ? ENTERPRISE :
                error("OAuth reached an unexpected GitHub host")
            fields = HTTP.URIs.queryparams(HTTP.URI("https://fixture.invalid/?" * body))
            client = domain == "github.com" ? "Ov23li8tweQw6odWQebz" : "Ov23ctDVkRmgkPke0Mmm"
            get(fields, "client_id", "") == client || error("Incorrect OAuth client for selected GitHub host")
            if path == "/login/device/code"
                DEVICE_REQUESTS[] += 1
                return jsonReply(Dict("device_code"=>"device-" * domain, "user_code"=>"GHE-SYSTEM",
                    "verification_uri"=>origin * "/login/device", "interval"=>0.02, "expires_in"=>120))
            elseif get(fields, "grant_type", "") == "refresh_token"
                domain == ENTERPRISE || error("Unexpected public refresh")
                get(fields, "refresh_token", "") == "enterprise-refresh-1" || error("Incorrect enterprise refresh grant")
                ENTERPRISE_REFRESHES[] += 1
                return jsonReply(Dict("access_token"=>"enterprise-access-2", "refresh_token"=>"enterprise-refresh-2", "expires_in"=>3600))
            end
            domain in APPROVED || return jsonReply(Dict("error"=>"authorization_pending"))
            return domain == "github.com" ? jsonReply(Dict("access_token"=>"public-access")) :
                jsonReply(Dict("access_token"=>"enterprise-access-1", "refresh_token"=>"enterprise-refresh-1", "expires_in"=>1))
        elseif path == "/copilot_internal/user"
            origin == "https://api.github.com" && auth == "token public-access" || error("Incorrect account discovery host")
            return jsonReply(Dict("endpoints"=>Dict("api"=>"https://api.business.githubcopilot.com")))
        elseif path == "/models"
            if origin == "https://api.business.githubcopilot.com" && auth == "Bearer public-access"
                if HOLD_PUBLIC[]
                    PUBLIC_HELD[] = true
                    while !RELEASE_PUBLIC[] && !FINISHED[]
                        sleep(0.02)
                    end
                    return modelReply("stale-public-model")
                end
                return modelReply("business-model")
            end
            origin == "https://copilot-api." * ENTERPRISE && auth == "Bearer enterprise-access-2" ||
                error("Incorrect tenant catalog destination or credential")
            return modelReply("enterprise-model")
        elseif path == "/chat/completions"
            payload = JSON3.read(body)
            enterprise = origin == "https://copilot-api." * ENTERPRISE
            expectedOrigin = enterprise ? "https://copilot-api." * ENTERPRISE : "https://api.business.githubcopilot.com"
            expectedToken = enterprise ? "Bearer enterprise-access-2" : "Bearer public-access"
            expectedModel = enterprise ? "enterprise-model" : "business-model"
            origin == expectedOrigin && auth == expectedToken && payload.model == expectedModel ||
                error("Inference did not use the selected account and model")
            enterprise ? (ENTERPRISE_COMPLETIONS[] += 1) : (PUBLIC_COMPLETIONS[] += 1)
            marker = enterprise ? "ENTERPRISE_SYSTEM_DONE" : "BUSINESS_SYSTEM_DONE"
            answer = JSON3.write(Dict("action"=>"done", "summary"=>marker))
            event = Dict("choices"=>[Dict("index"=>0, "delta"=>Dict("content"=>answer), "finish_reason"=>"stop")])
            return HTTP.Response(200, ["Content-Type"=>"text/event-stream"],
                "data: " * JSON3.write(event) * "\n\ndata: [DONE]\n\n")
        end
        error("Unexpected system fixture request")
    catch err
        return jsonReply(Dict("error"=>Dict("message"=>sprint(showerror,err))); status=400)
    end
end
const FIXTURE_PORT = Sockets.getsockname(FIXTURE.listener.server)[2]
ENV["FLOOTY_INFERENCE_URL"] = "http://127.0.0.1:$FIXTURE_PORT/v1"
ENV["FLOOTY_ACTOR_MODEL"] = "system-local"
ENV["FLOOTY_MONITOR_MODEL"] = "system-local"
using Flooty, FlootyPTYLayer
const F, L = Flooty, FlootyPTYLayer
const W = L.Webviews
# External provider traffic uses a real local HTTP server; no live identity service is contacted.
F.SUBSCRIPTION_HTTP[] = function(method,url,headers,body)
    uri = HTTP.URI(url)
    forwarded = [headers; "X-Flooty-System-Origin"=>uri.scheme * "://" * uri.host]
    return HTTP.request(method,"http://127.0.0.1:$FIXTURE_PORT" * uri.path,forwarded,body;
        status_exception=false,redirect=false,retry=false,readtimeout=30)
end
F.SUBSCRIPTION_STORE_READ[] = provider -> begin
    path = joinpath(SYSTEM_DIR,provider * ".json")
    isfile(path) ? read(path,String) : nothing
end
F.SUBSCRIPTION_STORE_WRITE[] = (provider,secret) -> begin
    path = joinpath(SYSTEM_DIR,provider * ".json")
    write(path,secret)
    chmod(path,0o600)
    nothing
end
F.SUBSCRIPTION_CLAUDE_PROCESS[] = (args,input,timeout,check,environment) -> (exitcode=1,stdout="{\"loggedIn\":false}")
F.agentApp(cmd=`/bin/zsh -f`,sessionsDir=SYSTEM_DIR,journalPath=joinpath(SYSTEM_DIR,"journal.sqlite"))
const WV = L.launchTerminalUI(cmd=`/bin/zsh -f`)
function finishSystemProbe()
    FINISHED[] && return
    FINISHED[] = true
    RELEASE_PUBLIC[] = true
    F.disableJournalPersistence!()
    try W.close(WV) catch; L.requestStopEventLoop!(WV) end
end
W.bind(WV,"flootyEnterpriseSystemControl") do args
    payload = L.jsonArgs(args)
    operation = String(get(payload,:operation,"state"))
    if operation == "approve"
        push!(APPROVED,String(payload.domain))
    elseif operation == "hold_public"
        HOLD_PUBLIC[] = true
    elseif operation == "release_public"
        RELEASE_PUBLIC[] = true
    end
    JSON3.write((success=true,devices=DEVICE_REQUESTS[],publicHeld=PUBLIC_HELD[],
        publicCompletions=PUBLIC_COMPLETIONS[],enterpriseCompletions=ENTERPRISE_COMPLETIONS[],
        enterpriseRefreshes=ENTERPRISE_REFRESHES[]))
end
W.bind(WV,"flootyEnterpriseSystemEvidence") do args
    payload = L.jsonArgs(args)
    path = joinpath(SYSTEM_DIR,"github-copilot.json")
    saved = isfile(path) ? JSON3.read(read(path,String)) : nothing
    persisted = saved !== nothing && saved.githubDomain == ENTERPRISE && saved.refresh == "enterprise-refresh-2"
    PASSED[] = get(payload,:passed,false) && persisted && PUBLIC_COMPLETIONS[] > 0 &&
        ENTERPRISE_COMPLETIONS[] > 0 && ENTERPRISE_REFRESHES[] == 1
    println("COPILOT_ENTERPRISE_SYSTEM_EVIDENCE ",JSON3.write((ui=payload,persisted=persisted,
        publicInference=PUBLIC_COMPLETIONS[],enterpriseInference=ENTERPRISE_COMPLETIONS[],refreshes=ENTERPRISE_REFRESHES[])))
    flush(stdout)
    W.set_timeout(finishSystemProbe,WV,0.2)
    L.jsonOk()
end
W.set_timeout(function()
    W.eval!(WV,raw"""
(async function () {
    const wait = async fn => {
        const until = Date.now()+30000;
        while (!await fn()) { if(Date.now()>until) throw Error('Native system UI condition timed out'); await new Promise(r=>setTimeout(r,50)); }
    };
    const control = async (operation='state',extra={}) => JSON.parse(await flootyEnterpriseSystemControl(JSON.stringify({operation,...extra})));
    const providers = async () => JSON.parse(await flootySubscription(JSON.stringify({operation:'providers'}))).providers;
    const click = text => { const button=[...document.querySelectorAll('#subscriptionDialog button')].find(b=>b.textContent===text); if(!button)throw Error('Missing dialog action: '+text);button.click(); };
    const type = (input,value) => {input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));};
    const open = async () => {
        type(document.querySelector('#assistTextarea'),'/login');document.querySelector('#assistSend').click();
        await wait(()=>document.querySelector('#subscriptionDialog')?.open);
        await wait(()=>[...document.querySelectorAll('.subscription-provider')].some(b=>b.textContent.startsWith('GitHub Copilot')&&!b.disabled));
        [...document.querySelectorAll('.subscription-provider')].find(b=>b.textContent.startsWith('GitHub Copilot')).click();
    };
    const host = async value => {
        await wait(()=>!document.querySelector('.subscription-host-form').hidden);
        type(document.querySelector('#subscriptionGithubHost'),value);
        document.querySelector('.subscription-host-form').requestSubmit();
    };
    const use = async model => {
        await wait(()=>[...document.querySelectorAll('#subscriptionModel option')].some(o=>o.value===model));
        document.querySelector('#subscriptionModel').value=model;click('Use model');
        await wait(()=>!document.querySelector('#subscriptionDialog').open);
    };
    const commission = async marker => {
        type(document.querySelector('#assistTextarea'),'Report done without running any commands.');
        document.querySelector('#assistSend').click();
        await wait(()=>document.querySelector('#agentChatLog').textContent.includes(marker));
    };
    try {
        await wait(()=>document.querySelector('#assistTextarea')&&typeof flootyEnterpriseSystemControl==='function'&&focusedSessionId());
        await open();
        await wait(()=>!document.querySelector('.subscription-host-form').hidden);
        const before=(await control()).devices;
        await host('http://company.ghe.com');
        await wait(()=>!document.querySelector('#subscriptionDialog [role=alert]').hidden);
        if((await control()).devices!==before||document.querySelector('#subscriptionGithubHost').disabled) throw Error('Invalid host started OAuth or blocked correction');
        await host('');
        await wait(()=>document.querySelector('#subscriptionDeviceCode'));
        await control('approve',{domain:'github.com'});
        await use('business-model');
        const chooseModel = async (id,model) => {
            await wait(()=>[...document.querySelector(id).options].some(o=>o.value===model));
            const select=document.querySelector(id);
            select.value=model;select.dispatchEvent(new Event('change',{bubbles:true}));
            await wait(()=>!select.disabled);
            const role=id==='#modelSelect'?'current':'monitor';
            await wait(async()=> (await callJulia('flootyModels',JSON.stringify({terminal_id:activeModelSessionId()})))[role]===model);
        };
        await chooseModel('#monitorSelect','system-monitor');
        await chooseModel('#modelSelect','system-local');
        await chooseModel('#modelSelect','github-copilot/business-model');
        if(document.querySelector('#monitorSelect').value!=='system-monitor') throw Error('Changing the agent overwrote the monitor selection');
        await commission('BUSINESS_SYSTEM_DONE');
        await wait(async()=> (await control()).publicCompletions>0);
        await control('hold_public');
        await open();
        await wait(async()=> (await control()).publicHeld);
        click('Sign in with another GitHub host');
        await host('https://COMPANY.GHE.COM:443/');
        await wait(()=>document.querySelector('#subscriptionDeviceCode'));
        click('Choose another subscription');
        await wait(()=>[...document.querySelectorAll('.subscription-provider')].some(b=>b.textContent.includes('connected (github.com)')));
        [...document.querySelectorAll('.subscription-provider')].find(b=>b.textContent.startsWith('GitHub Copilot')).click();
        click('Sign in with another GitHub host');
        if(document.querySelector('#subscriptionGithubHost').value!=='https://COMPANY.GHE.COM:443/') throw Error('Retry lost the selected GitHub host');
        document.querySelector('.subscription-host-form').requestSubmit();
        await wait(()=>document.querySelector('#subscriptionDeviceCode'));
        await control('approve',{domain:'company.ghe.com'});
        await wait(()=>[...document.querySelectorAll('#subscriptionModel option')].some(o=>o.value==='enterprise-model'));
        await control('release_public');
        await wait(async()=> !(await providers()).find(p=>p.id==='github-copilot').checking);
        await use('enterprise-model');
        await commission('ENTERPRISE_SYSTEM_DONE');
        await wait(async()=> (await control()).enterpriseCompletions>0);
        await flootyEnterpriseSystemEvidence(JSON.stringify({passed:true,hostSelection:true,invalidHost:true,
            cancelledLoginPreservedAccount:true,tenantCutover:true,publicAndEnterpriseInference:true,independentModelPickers:true}));
    } catch(error) {
        await flootyEnterpriseSystemEvidence(JSON.stringify({passed:false,error:error.message}));
    }
})();
""")
end,WV,2.0)
W.set_timeout(function()
    FINISHED[] || println("COPILOT_ENTERPRISE_SYSTEM_WATCHDOG")
    finishSystemProbe()
end,WV,80.0)
try
    L.runEventLoopAndTeardown!(WV)
finally
    RELEASE_PUBLIC[] = true
    close(FIXTURE)
end
PASSED[] || exit(1)
println("COPILOT_ENTERPRISE_SYSTEM_PROBE_OK")
