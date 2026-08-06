function [resp, history, audit] = vaayuRespond(model, userMessage, history)
%vaayuRespond Route a VAAYU user message to chat text or a structured tool call.
arguments (Input)
    % Text generation model used for primary agent tool selection
    model
    % User request text from chat or speech transcription
    userMessage (1,1) string
    % Rolling messageHistory object used by the router LLM
    history = []
end
arguments (Output)
    % Response struct with type, speak, tool, and params fields
    resp struct
    % Updated rolling messageHistory object
    history
    % Routing audit with raw LLM response, parsed fields, deterministic route details, and errors
    audit struct
end

if isempty(history)
    history = messageHistory;
end

audit = struct( ...
    'stage', "route_intent", ...
    'userMessage', userMessage, ...
    'rawLLMResponse', "", ...
    'parsedType', "", ...
    'parsedTool', "", ...
    'parsedParams', struct(), ...
    'didParse', false, ...
    'primaryDecisionSource', "", ...
    'validation', struct('isValid', false, 'reason', ""), ...
    'fallbackReason', "", ...
    'errorMessage', "");

history = addUserMessage(history, userMessage);

if ~isempty(model)
    try
        raw = generate(model, history);
        audit.rawLLMResponse = string(raw);
        [parsed, normalizedRaw] = parseAgentJSON(raw);
        audit.rawLLMResponse = normalizedRaw;
        [candidate, validation] = normalizeAgentResponse(parsed, userMessage);
        audit.validation = validation;
        audit.didParse = true;

        if validation.isValid
            resp = candidate;
            audit.primaryDecisionSource = "llm";
            audit.parsedType = resp.type;
            audit.parsedTool = resp.tool;
            audit.parsedParams = resp.params;
            history = addResponseMessage(history, struct( ...
                'role', 'assistant', ...
                'content', char(encodeRouteResponse(resp))));
            history = trimHistory(history);
            return;
        end
    catch ME
        audit.errorMessage = string(ME.message);
        audit.validation = struct('isValid', false, 'reason', "llm_exception");
    end
else
    audit.validation = struct('isValid', false, 'reason', "no_model_supplied");
end

[resp, detAudit, fallbackReason] = deterministicFallback(userMessage, audit.validation.reason);
audit.primaryDecisionSource = "deterministic_fallback";
audit.fallbackReason = fallbackReason;
audit.deterministicRoute = detAudit;
audit.parsedType = resp.type;
audit.parsedTool = resp.tool;
audit.parsedParams = resp.params;
audit.didParse = resp.type ~= "";

history = addResponseMessage(history, struct( ...
    'role', 'assistant', ...
    'content', char(encodeRouteResponse(resp))));

% Keep rolling window of last 10 messages (5 user + 5 assistant)
history = trimHistory(history);
end

function [parsed, normalizedRaw] = parseAgentJSON(raw)
normalizedRaw = stripJSONFences(raw);
parsed = jsondecode(char(normalizedRaw));
normalizedRaw = string(jsonencode(parsed));
end

function text = stripJSONFences(text)
text = strtrim(string(text));
text = replace(text, ["“", "”"], """");
text = regexprep(text, '^\s*```json\s*', '');
text = regexprep(text, '^\s*```\s*', '');
text = regexprep(text, '\s*```\s*$', '');
text = strtrim(text);
end

function [resp, validation] = normalizeAgentResponse(parsed, userMessage)
resp = struct('type', "chat", 'speak', "", 'tool', "", 'params', struct());
validation = struct('isValid', false, 'reason', "");

if ~isstruct(parsed) || ~isfield(parsed, 'type')
    validation.reason = "missing_type";
    return;
end

resp.type = lower(string(parsed.type));
switch resp.type
    case "chat"
        if ~isfield(parsed, 'speak')
            validation.reason = "chat_missing_speak";
            return;
        end
        resp.speak = sanitizeSpeech(string(parsed.speak));
        validation.isValid = resp.speak ~= "";
        if ~validation.isValid
            validation.reason = "empty_chat_speak";
        end

    case "tool"
        if ~isfield(parsed, 'tool') || strlength(string(parsed.tool)) == 0
            validation.reason = "tool_missing_name";
            return;
        end

        [toolName, foundTool] = canonicalToolName(string(parsed.tool));
        if ~foundTool
            validation.reason = "unknown_tool";
            return;
        end

        resp.tool = toolName;
        if isfield(parsed, 'params') && isstruct(parsed.params)
            resp.params = normalizeParams(parsed.params);
        else
            resp.params = struct('engine_id', "fleet");
        end
        resp.params = repairMissingEngineID(resp.tool, resp.params, userMessage);
        if isfield(parsed, 'speak')
            resp.speak = sanitizeToolAcknowledgment(string(parsed.speak));
        else
            resp.speak = defaultToolAcknowledgment();
        end
        validation.isValid = true;

    otherwise
        validation.reason = "unsupported_type";
end
end

function params = normalizeParams(params)
if ~isfield(params, 'engine_id')
    params.engine_id = "fleet";
else
    eid = params.engine_id;
    if isempty(eid) || isequal(eid, 0)
        params.engine_id = "fleet";
    elseif isnumeric(eid)
        params.engine_id = sprintf("MW-%03d", eid);
    else
        params.engine_id = string(eid);
    end
end

if isfield(params, 'max_results') && ~isempty(params.max_results)
    params.max_results = max(1, floor(double(params.max_results)));
end
end

function [resp, detAudit, reason] = deterministicFallback(userMessage, validationReason)
[resp, detAudit] = vaayuTools.routeFleetQuery(userMessage);
reason = "llm_invalid_" + string(validationReason);
if detAudit.didRoute
    if resp.type == "tool" && strlength(string(resp.speak)) == 0
        resp.speak = defaultToolAcknowledgment();
    end
    return;
end

inferredID = inferEngineID(userMessage);
if inferredID ~= ""
    resp = struct('type', "tool", 'speak', "", ...
        'tool', "analyze_engine", 'params', struct('engine_id', inferredID));
    resp.speak = defaultToolAcknowledgment();
    detAudit.didRoute = true;
    detAudit.parsedTool = resp.tool;
    detAudit.parsedParams = resp.params;
    detAudit.reason = "fallback_engine_id";
    return;
end

resp = struct('type', "chat", ...
    'speak', "I did not get that cleanly. Please repeat the request.", ...
    'tool', "", 'params', struct());
end

function text = encodeRouteResponse(resp)
if resp.type == "tool"
    text = string(jsonencode(struct( ...
        'type', char(resp.type), ...
        'speak', char(resp.speak), ...
        'tool', char(resp.tool), ...
        'params', resp.params)));
else
    text = string(jsonencode(struct( ...
        'type', char(resp.type), ...
        'speak', char(resp.speak))));
end
end

function history = trimHistory(history)
if numel(history.Messages) > 10
    for k = 1:(numel(history.Messages) - 10)
        history = removeMessage(history, 1);
    end
end
end

function text = sanitizeSpeech(text)
text = strip(string(text));
if text == ""
    return;
end

looksLikeJson = startsWith(text, "{") || contains(text, """type""") || ...
    contains(text, """speak""") || contains(text, "```json");
if looksLikeJson
    text = "I did not get that cleanly. Please repeat the request.";
    return;
end

text = regexprep(text, '\bH\s*I\b', 'health indicator', 'ignorecase');
text = regexprep(text, '\s+', ' ');
text = string(strip(text));
end

function text = sanitizeToolAcknowledgment(text)
text = sanitizeSpeech(text);
if text == "" || text == "I did not get that cleanly. Please repeat the request."
    text = defaultToolAcknowledgment();
    return;
end

forbidden = ["RUL", "health indicator", "HI", "confidence", "critical", ...
    "degrading", "healthy", "maintenance", "MW-"];
if contains(text, forbidden, 'IgnoreCase', true)
    text = defaultToolAcknowledgment();
end
end

function text = defaultToolAcknowledgment()
text = "Checking that now, Sir.";
end

function params = repairMissingEngineID(toolName, params, userMessage)
if ~isEngineTool(toolName)
    return;
end

if ~isfield(params, 'engine_id') || isEmptyEngineID(params.engine_id)
    inferredID = inferEngineID(userMessage);
    if inferredID ~= ""
        params.engine_id = inferredID;
    end
end
end

function tf = isEngineTool(toolName)
tf = any(toolName == ["analyze_engine", "check_engine", "engine_status", ...
    "predict_failure", "explain_engine"]);
end

function tf = isEmptyEngineID(value)
tf = isempty(value) || isequal(value, 0);
if ~tf && (isstring(value) || ischar(value))
    text = lower(strip(string(value)));
    tf = text == "" || text == "null" || text == "fleet";
end
end

function [canonicalName, foundTool] = canonicalToolName(toolName)
tools = vaayuTools.catalog();
canonicalName = string(toolName);
foundTool = false;
for idx = 1:numel(tools)
    if canonicalName == tools(idx).Name || any(canonicalName == tools(idx).Aliases)
        canonicalName = tools(idx).Name;
        foundTool = true;
        return;
    end
end
end

function engineID = inferEngineID(userMessage)
text = upper(char(userMessage));
mwToken = regexp(text, 'MW[-\s]?(\d+)', 'tokens', 'once');
if ~isempty(mwToken)
    engineID = sprintf("MW-%03d", str2double(mwToken{1}));
    return;
end

numberToken = regexp(text, '\d+', 'match', 'once');
if ~isempty(numberToken)
    engineID = sprintf("MW-%03d", str2double(numberToken));
else
    engineID = "";
end
end
