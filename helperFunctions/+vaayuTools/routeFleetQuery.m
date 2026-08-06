function [resp, audit] = routeFleetQuery(userMessage)
%routeFleetQuery Route a user fleet query to a VAAYU tool name and parameter struct.

arguments (Input)
    % User request text from the VAAYU chat or voice interface
    userMessage (1,1) string
end
arguments (Output)
    % Route response with type, tool, speak, and params fields
    resp struct
    % Routing audit with parsed tool, parsed params, route reason, and parse status
    audit struct
end

resp = struct('type', "chat", 'speak', "", 'tool', "", 'params', struct());
audit = struct( ...
    'stage', "deterministic_route_intent", ...
    'userMessage', userMessage, ...
    'didRoute', false, ...
    'parsedTool', "", ...
    'parsedParams', struct(), ...
    'reason', "");

text = normalizeText(userMessage);
engineID = inferEngineID(text);
requestedCount = inferRequestedCount(text);

toolName = "";
reason = "";

if containsAny(text, ["highest risk", "riskiest", "worst engine", ...
        "least health indicator", "lowest health indicator", "least hi", "lowest hi"])
    toolName = "check_highest_risk_engine";
    reason = "highest_risk_keywords";
elseif containsAny(text, ["top risk", "top-risk", "risk engines", "riskiest engines"])
    toolName = "check_top_risk_engines";
    reason = "top_risk_keywords";
elseif contains(text, "maintenance") || contains(text, "maint")
    if containsAny(text, ["which", "list", "show", "failure mode", "failure modes", "for which"])
        toolName = "list_maintenance_engines";
        reason = "maintenance_list_keywords";
    else
        toolName = "check_maintenance_engines";
        reason = "maintenance_count_keywords";
    end
elseif contains(text, "airborne") || contains(text, "in air") || contains(text, "flying")
    if containsAny(text, ["which", "list", "show"])
        toolName = "list_airborne_engines";
        reason = "airborne_list_keywords";
    else
        toolName = "check_airborne_engines";
        reason = "airborne_count_keywords";
    end
elseif contains(text, "critical")
    toolName = "check_critical_engines";
    reason = "critical_keywords";
elseif containsAny(text, ["early failure", "early-failure"])
    toolName = "check_early_failure_engines";
    reason = "early_failure_keywords";
elseif containsAny(text, ["degrading", "degradation", "at risk", "warning"])
    toolName = "check_degrading_engines";
    reason = "degrading_keywords";
elseif containsAny(text, ["cluster", "bucket", "buckets", "operating state", "operational state"])
    toolName = "check_operational_clusters";
    reason = "cluster_keywords";
elseif engineID ~= ""
    if containsAny(text, ["predict", "rul", "remaining useful", "failure horizon"])
        toolName = "predict_failure";
        reason = "engine_prediction_keywords";
    elseif containsAny(text, ["explain", "why", "anomaly", "diagnostic", "diagnose"])
        toolName = "explain_engine";
        reason = "engine_explanation_keywords";
    else
        toolName = "analyze_engine";
        reason = "engine_id_keywords";
    end
elseif containsAny(text, ["fleet", "fleet status", "status now", "health status", ...
        "engines total", "overall", "summary"])
    toolName = "check_fleet";
    reason = "fleet_summary_keywords";
end

if toolName == ""
    return;
end

params = struct('engine_id', "fleet");
if engineID ~= ""
    params.engine_id = engineID;
end
if toolName == "check_top_risk_engines" && isfinite(requestedCount)
    params.max_results = requestedCount;
end

resp.type = "tool";
resp.tool = toolName;
resp.params = params;
resp.speak = "";

audit.didRoute = true;
audit.parsedTool = toolName;
audit.parsedParams = params;
audit.reason = reason;
end

function requestedCount = inferRequestedCount(text)
requestedCount = Inf;
topToken = regexp(char(text), 'top\s+(\d+)', 'tokens', 'once');
if ~isempty(topToken)
    requestedCount = str2double(topToken{1});
    return;
end

numberToken = regexp(char(text), '(\d+)\s+(risk|riskiest|critical|degrading)', 'tokens', 'once');
if ~isempty(numberToken)
    requestedCount = str2double(numberToken{1});
end
end

function text = normalizeText(userMessage)
text = lower(strip(string(userMessage)));
text = regexprep(text, '^\s*(why you|wei u|wai you|way you|vayu|vaayu)[, ]+', '');
text = replace(text, "-", " ");
text = regexprep(text, '\s+', ' ');
end

function tf = containsAny(text, needles)
tf = false;
for needle = string(needles)
    if contains(text, needle)
        tf = true;
        return;
    end
end
end

function engineID = inferEngineID(text)
mwToken = regexp(char(text), 'mw\s?(\d+)', 'tokens', 'once');
if ~isempty(mwToken)
    engineID = sprintf("MW-%03d", str2double(mwToken{1}));
    return;
end

engineToken = regexp(char(text), '\bengine\s+(\d+)\b', 'tokens', 'once');
if ~isempty(engineToken)
    engineID = sprintf("MW-%03d", str2double(engineToken{1}));
else
    engineID = "";
end
end
