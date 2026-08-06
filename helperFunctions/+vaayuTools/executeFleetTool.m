function [result, audit] = executeFleetTool(toolName, params)
%executeFleetTool Execute a VAAYU FleetAnalytics tool and return structured data plus trace audit.

arguments (Input)
    % Canonical tool name or alias
    toolName (1,1) string
    % Tool parameters; accepts engine_id as string or numeric scalar and max_results as positive integer scalar or Inf
    params struct = struct('engine_id', "")
end
arguments (Output)
    % Structured tool result returned by queryFleetHealth
    result struct
    % Tool execution audit containing routing, normalized query, underlying function, and error fields
    audit struct
end

projectRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(fullfile(projectRoot, 'FleetAnalytics'));

audit = struct( ...
    'stage', "execute_tool", ...
    'requestedTool', toolName, ...
    'requestedParams', params, ...
    'normalizedQuery', "", ...
    'underlyingFunction', "queryFleetHealth", ...
    'didRunUnderlyingFunction', false, ...
    'errorMessage', "");

try
    switch canonicalToolName(toolName)
        case {"analyze_engine", "predict_failure", "explain_engine"}
            engID = extractEngineID(params);
            audit.normalizedQuery = engID;
            result = queryFleetHealth(engID);

        case "check_fleet"
            audit.normalizedQuery = "fleet";
            result = queryFleetHealth("fleet");

        case "check_operational_clusters"
            audit.normalizedQuery = "clusters";
            result = queryFleetHealth("clusters");

        case "check_airborne_engines"
            audit.normalizedQuery = "airborne_count";
            result = queryFleetHealth("airborne_count");

        case "list_airborne_engines"
            audit.normalizedQuery = "airborne";
            result = queryFleetHealth("airborne");

        case "check_maintenance_engines"
            audit.normalizedQuery = "maintenance_count";
            result = queryFleetHealth("maintenance_count");

        case "list_maintenance_engines"
            audit.normalizedQuery = "maintenance";
            result = queryFleetHealth("maintenance");

        case "check_degrading_engines"
            audit.normalizedQuery = "degrading";
            result = queryFleetHealth("degrading");

        case "check_critical_engines"
            audit.normalizedQuery = "critical";
            result = queryFleetHealth("critical");

        case "check_early_failure_engines"
            audit.normalizedQuery = "early_failure";
            result = queryFleetHealth("early_failure");

        case "check_top_risk_engines"
            audit.normalizedQuery = "top_risk";
            result = queryFleetHealth("top_risk", extractMaxResults(params));

        case "check_highest_risk_engine"
            audit.normalizedQuery = "highest_risk";
            result = queryFleetHealth("highest_risk");

        otherwise
            engID = extractEngineID(params);
            if engID ~= "" && engID ~= "fleet"
                audit.normalizedQuery = engID;
                result = queryFleetHealth(engID);
            else
                audit.normalizedQuery = "fleet";
                result = queryFleetHealth("fleet");
            end
    end
    audit.didRunUnderlyingFunction = true;
catch ME
    audit.errorMessage = string(ME.message);
    result = struct( ...
        'error', true, ...
        'message', sprintf('Fleet analytics query failed: %s', ME.message), ...
        'requestedTool', toolName, ...
        'normalizedQuery', audit.normalizedQuery);
end
end

function maxResults = extractMaxResults(params)
if isfield(params, 'max_results') && ~isempty(params.max_results)
    maxResults = double(params.max_results);
elseif isfield(params, 'top_n') && ~isempty(params.top_n)
    maxResults = double(params.top_n);
else
    maxResults = Inf;
end

if ~isfinite(maxResults)
    maxResults = Inf;
else
    maxResults = max(1, floor(maxResults));
end
end

function canonicalName = canonicalToolName(toolName)
toolName = string(toolName);
tools = vaayuTools.catalog();
canonicalName = toolName;
for idx = 1:numel(tools)
    if toolName == tools(idx).Name || any(toolName == tools(idx).Aliases)
        canonicalName = tools(idx).Name;
        return;
    end
end
end

function engID = extractEngineID(params)
if isfield(params, 'engine_id')
    val = params.engine_id;
    if isempty(val) || isequal(val, 0) || (isstring(val) && (val == "" || val == "null" || val == "fleet"))
        engID = "fleet";
    elseif isnumeric(val)
        engID = sprintf("MW-%03d", val);
    else
        engID = normalizeEngineID(string(val));
    end
else
    engID = "fleet";
end
end

function engID = normalizeEngineID(value)
value = upper(strip(value));
if value == "" || value == "NULL" || value == "FLEET"
    engID = "fleet";
    return;
end

mwToken = regexp(char(value), 'MW[-\s]?(\d+)', 'tokens', 'once');
if ~isempty(mwToken)
    engID = sprintf("MW-%03d", str2double(mwToken{1}));
    return;
end

numToken = regexp(char(value), '\d+', 'match', 'once');
if ~isempty(numToken)
    engID = sprintf("MW-%03d", str2double(numToken));
else
    engID = value;
end
end
