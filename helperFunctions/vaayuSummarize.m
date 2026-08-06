function resp = vaayuSummarize(model, originalQuery, toolResult)
%vaayuSummarize Summarize structured VAAYU tool results with an LLM when available.

arguments (Input)
    % Text generation model used for final response synthesis; pass [] to use deterministic offline fallback
    model
    % Original user request, preserved so the final response can honor requested scope such as top 5
    originalQuery (1,1) string
    % Structured output returned by vaayuTools.executeFleetTool or queryFleetHealth
    toolResult
end
arguments (Output)
    % Response struct with speak, followup, and audit fields
    resp struct
end

resp = struct('speak', "", 'followup', "", 'audit', struct());
llmAudit = struct();

if isstruct(toolResult) && isfield(toolResult, 'error') && logical(toolResult.error)
    if isfield(toolResult, 'message')
        resp.speak = string(toolResult.message);
    else
        resp.speak = "Fleet analytics returned an error, Sir.";
    end
    resp.audit = buildAudit(resp.speak, toolResult, "error");
    resp.audit.originalQuery = originalQuery;
    resp.audit.finalResponseJSON = encodeFinalResponseJSON(resp);
    return;
end

if ~isempty(model)
    [llmText, llmAudit] = summarizeWithLLM(model, originalQuery, toolResult);
    if llmText ~= ""
        responseKind = inferResponseKind(toolResult);
        resp.speak = llmText;
        resp.followup = extractFollowupFromRawJSON(llmAudit.rawResponse);
        resp.audit = buildAudit(resp.speak, toolResult, responseKind);
        resp.audit.stage = "llm_summary";
        resp.audit.usedLLMForFinalResponse = true;
        resp.audit.originalQuery = originalQuery;
        resp.audit.llm = llmAudit;
        resp.audit.finalResponseJSON = encodeFinalResponseJSON(resp);
        return;
    end
end

if isstruct(toolResult) && isfield(toolResult, 'queryKind') && toolResult.queryKind == "highest_risk"
    resp.speak = renderHighestRisk(toolResult);
    responseKind = "highest_risk";
elseif isstruct(toolResult) && isfield(toolResult, 'queryKind') && toolResult.queryKind == "top_risk"
    resp.speak = renderTopRisk(toolResult);
    responseKind = "top_risk";
elseif isstruct(toolResult) && isfield(toolResult, 'queryKind') && toolResult.queryKind == "clusters"
    resp.speak = renderClusters(toolResult);
    responseKind = "clusters";
elseif isstruct(toolResult) && isfield(toolResult, 'opState') && isfield(toolResult, 'operatingStates')
    resp.speak = renderOperatingStateCount(toolResult);
    responseKind = "operating_state_count";
elseif isstruct(toolResult) && isfield(toolResult, 'opState') && isfield(toolResult, 'engines')
    resp.speak = renderOperatingStateList(toolResult);
    responseKind = "operating_state_list";
elseif isstruct(toolResult) && isfield(toolResult, 'bucket') && isfield(toolResult, 'engines')
    resp.speak = renderEngineList(toolResult, string(toolResult.bucket));
    responseKind = string(toolResult.queryKind);
elseif isstruct(toolResult) && isfield(toolResult, 'engineID')
    resp.speak = renderEngine(toolResult);
    responseKind = "engine";
elseif isstruct(toolResult) && isfield(toolResult, 'nHealthy') && isfield(toolResult, 'nMaintenance')
    resp.speak = renderFleet(toolResult);
    responseKind = "fleet";
elseif isstruct(toolResult) && isfield(toolResult, 'engines') && isfield(toolResult, 'nDegrading')
    resp.speak = renderDegrading(toolResult);
    responseKind = "degrading";
elseif isstruct(toolResult) && isfield(toolResult, 'message')
    resp.speak = string(toolResult.message);
    responseKind = "message";
else
    resp.speak = "The fleet analytics tool returned data, Sir, but I could not format it deterministically.";
    responseKind = "unknown";
end

resp.audit = buildAudit(resp.speak, toolResult, responseKind);
resp.audit.originalQuery = originalQuery;
if ~isempty(fieldnames(llmAudit))
    resp.audit.llm = llmAudit;
end
resp.audit.finalResponseJSON = encodeFinalResponseJSON(resp);
end

function [text, audit] = summarizeWithLLM(model, originalQuery, toolResult)
audit = struct( ...
    'didInvokeLLM', false, ...
    'modelClass', string(class(model)), ...
    'rawResponse', "", ...
    'errorMessage', "");

try
    prompt = buildSummaryPrompt(originalQuery, toolResult);
    audit.didInvokeLLM = true;
    if isa(model, "ollamaChat")
        summaryModel = ollamaChat(model.Model, summarySystemPrompt(), ...
            Temperature=0.2, ResponseFormat="json", TimeOut=120);
        raw = generate(summaryModel, prompt, MaxNumTokens=450);
    else
        raw = generate(model, prompt);
    end
    [text, parseError, normalizedRaw] = parseSummaryJSON(raw);
    audit.rawResponse = normalizedRaw;
    audit.errorMessage = parseError;
catch ME
    audit.errorMessage = string(ME.message);
    text = "";
end
end

function prompt = buildSummaryPrompt(originalQuery, toolResult)
payload = jsonencode(toolResult);
prompt = strjoin([ ...
    "User request:" ...
    originalQuery ...
    "" ...
    "Authoritative VAAYU FleetAnalytics tool result JSON:" ...
    string(payload) ...
    "" ...
    "Return ONLY this JSON shape with no markdown and no text outside JSON:" ...
    "{""speak"":""spoken answer using only the tool JSON facts"",""followup"":""""}" ...
    "Preserve counts, engine IDs, RUL values, health indicators, confidence values, operating states, and tick index exactly. If the request asks for a number of engines such as top 5, list that many when present in engineRecords or say only the returned count is available. Use natural follow-up style, but do not invent facts. Say health indicator instead of HI. Keep speak concise."], newline);
end

function prompt = summarySystemPrompt()
prompt = strjoin([ ...
    "You are VAAYU, a precision engineering AI assistant for aircraft fleet health." ...
    "Summarize structured tool output into a concise spoken answer inside strict JSON." ...
    "You MUST return only valid JSON with fields speak and followup." ...
    "The tool JSON is authoritative. Do not recalculate, infer hidden values, or add engines not present in the JSON." ...
    "Honor the user's requested scope and wording, including requested list length."], newline);
end

function [text, errorMessage, normalizedRaw] = parseSummaryJSON(raw)
text = "";
errorMessage = "";
normalizedRaw = "";
raw = stripJSONFences(raw);
if raw == ""
    errorMessage = "empty_llm_response";
    return;
end

try
    parsed = jsondecode(char(raw));
    normalizedRaw = string(jsonencode(parsed));
    if ~isstruct(parsed) || ~isfield(parsed, 'speak')
        errorMessage = "missing_speak";
        return;
    end
    text = sanitizeSummarySpeech(string(parsed.speak));
catch ME
    errorMessage = string(ME.message);
end
end

function text = stripJSONFences(text)
text = strtrim(string(text));
text = regexprep(text, '^\s*```json\s*', '');
text = regexprep(text, '^\s*```\s*', '');
text = regexprep(text, '\s*```\s*$', '');
text = strtrim(text);
end

function text = sanitizeSummarySpeech(text)
text = strip(string(text));
text = regexprep(text, '\bH\s*I\b', 'health indicator', 'ignorecase');
text = regexprep(text, '\s+', ' ');
text = string(strip(text));
end

function responseKind = inferResponseKind(toolResult)
if isstruct(toolResult) && isfield(toolResult, 'queryKind')
    responseKind = string(toolResult.queryKind);
elseif isstruct(toolResult) && isfield(toolResult, 'engineID')
    responseKind = "engine";
elseif isstruct(toolResult) && isfield(toolResult, 'nHealthy') && isfield(toolResult, 'nMaintenance')
    responseKind = "fleet";
elseif isstruct(toolResult) && isfield(toolResult, 'message')
    responseKind = "message";
else
    responseKind = "unknown";
end
end

function text = extractFollowupFromRawJSON(rawResponse)
text = "";
if strlength(string(rawResponse)) == 0
    return;
end

try
    parsed = jsondecode(char(rawResponse));
    if isfield(parsed, 'followup')
        text = string(parsed.followup);
    end
catch
end
end

function text = encodeFinalResponseJSON(resp)
text = string(jsonencode(struct( ...
    'speak', char(resp.speak), ...
    'followup', char(resp.followup))));
end

function text = renderFleet(r)
text = sprintf(['Fleet snapshot tick %s: %d engines total. ' ...
    'Healthy %d, degrading %d, critical %d, early failure %d, maintenance %d. ' ...
    'Average health indicator %.3f.'], ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    r.nTotal, r.nHealthy, r.nDegrading, r.nCritical, ...
    r.nEarlyFailure, r.nMaintenance, r.avgHI);
text = string(text);
end

function text = renderClusters(r)
op = r.operatingStates;
text = sprintf(['Dashboard tick %s clusters: Healthy %d, degrading %d, critical %d, ' ...
    'early failure %d, maintenance %d. Operating states: airborne %d, just landed %d, ' ...
    'ground idle %d, departure in 2 hours %d, departure in 6 hours %d.'], ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    r.nHealthy, r.nDegrading, r.nCritical, r.nEarlyFailure, r.nMaintenance, ...
    op.Airborne, op.JustLanded, op.GroundIdle, op.DepartureIn2Hrs, op.DepartureIn6Hrs);
text = string(text);
end

function text = renderOperatingStateCount(r)
op = r.operatingStates;
text = sprintf(['At dashboard tick %s, %d of %d engines are %s. ' ...
    'Other operating states: airborne %d, just landed %d, ground idle %d, ' ...
    'departure in 2 hours %d, departure in 6 hours %d, maintenance %d.'], ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    r.count, r.nTotal, lower(char(r.opState)), op.Airborne, op.JustLanded, ...
    op.GroundIdle, op.DepartureIn2Hrs, op.DepartureIn6Hrs, op.Maintenance);
text = string(text);
end

function text = renderOperatingStateList(r)
if r.count == 0
    text = sprintf('At dashboard tick %s, no engines are %s.', ...
        formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), lower(char(r.opState)));
    text = string(text);
    return;
end

records = getFieldOrDefault(r, 'engineRecords', []);
if isempty(records)
    text = renderEngineList(r, lower(string(r.opState)));
    return;
end

if string(r.opState) == "Maintenance"
    maxDetails = min(6, numel(records));
    statePhrase = "in maintenance";
else
    maxDetails = min(3, numel(records));
    statePhrase = lower(friendlyOpState(r.opState));
end

details = renderRecordDetails(records, maxDetails);
suffix = "";
if r.count > maxDetails
    suffix = sprintf(' There are %d more in this group.', r.count - maxDetails);
end
text = sprintf('At dashboard tick %s, %d of %d engines are %s. %s%s', ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    r.count, r.nTotal, statePhrase, details, suffix);
text = string(text);
end

function text = renderTopRisk(r)
records = getFieldOrDefault(r, 'engineRecords', []);
criticalCount = getFieldOrDefault(r, 'nCritical', getFieldOrDefault(r, 'nAtRisk', 0));
if criticalCount == 0
    text = sprintf('At dashboard tick %s, there are no critical engines in the active fleet.', ...
        formatTick(getFieldOrDefault(r, 'tickIndex', NaN)));
    text = string(text);
    return;
end

detailCount = numel(records);
details = renderRecordDetails(records, detailCount);
text = sprintf(['At dashboard tick %s, %d engines are in the critical risk bucket. ' ...
    'The returned top %d by lowest health indicator are: %s'], ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    criticalCount, detailCount, details);
text = string(text);
end

function text = renderEngineList(r, label)
engines = string(r.engines(:));
topN = min(5, numel(engines));
topText = strjoin(engines(1:topN), '; ');
suffix = "";
if numel(engines) > topN
    suffix = sprintf(' Plus %d more.', numel(engines) - topN);
end

countValue = getFieldOrDefault(r, 'count', numel(engines));
nTotalText = "";
if isfield(r, 'nTotal')
    nTotalText = sprintf(' out of %d total', r.nTotal);
end
text = sprintf('At dashboard tick %s, %d engines are %s%s. %s.%s', ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    countValue, label, nTotalText, topText, suffix);
text = string(text);
end

function text = renderHighestRisk(r)
if ~isfield(r, 'engineID')
    text = string(r.message);
    return;
end

text = sprintf(['At dashboard tick %s, the highest-risk engine is %s. ' ...
    'Its active failure mode is %s, its current operational state is %s, and the risk status is %s. ' ...
    'Remaining useful life is %s, health indicator is %.3f, and the fault classifier model confidence is %.1f%%.'], ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    string(r.engineID), friendlyFailureMode(r.faultClass), friendlyOpState(r.opState), upper(string(r.status)), ...
    formatRUL(getFieldOrDefault(r, 'rul', Inf)), ...
    getFieldOrDefault(r, 'healthIndicator', NaN), ...
    getFieldOrDefault(r, 'confidence', NaN));
text = string(text);
end

function text = renderDegrading(r)
tickText = formatTick(getFieldOrDefault(r, 'tickIndex', NaN));
if r.nDegrading == 0
    text = sprintf('At dashboard tick %s, no operational engines are degrading or critical risk out of %d total.', ...
        tickText, r.nTotal);
    text = string(text);
    return;
end

engines = string(r.engines(:));
topN = min(5, numel(engines));
topText = strjoin(engines(1:topN), '; ');
suffix = "";
if numel(engines) > topN
    suffix = sprintf(' Plus %d more.', numel(engines) - topN);
end

text = sprintf('At dashboard tick %s, %d operational engines are degrading or critical risk out of %d total. Top risks: %s.%s', ...
    tickText, r.nDegrading, r.nTotal, topText, suffix);
text = string(text);
end

function text = renderEngine(r)
text = sprintf(['At dashboard tick %s, %s is currently %s. ' ...
    'The active failure mode is %s, with status %s. ' ...
    'Remaining useful life is %s, health indicator is %.3f, and the fault classifier model confidence is %.1f%%.'], ...
    formatTick(getFieldOrDefault(r, 'tickIndex', NaN)), ...
    string(r.engineID), ...
    friendlyOpState(r.opState), friendlyFailureMode(r.faultClass), upper(string(r.status)), ...
    formatRUL(getFieldOrDefault(r, 'rul', Inf)), ...
    getFieldOrDefault(r, 'healthIndicator', NaN), ...
    getFieldOrDefault(r, 'confidence', NaN));
text = string(text);
if ~isfinite(getFieldOrDefault(r, 'rul', Inf)) && isfield(r, 'rulExplanation') && strlength(string(r.rulExplanation)) > 0
    text = text + " " + string(r.rulExplanation);
end
end

function text = renderRecordDetails(records, maxCount)
if isempty(records) || maxCount == 0
    text = "";
    return;
end

parts = strings(maxCount, 1);
for idx = 1:maxCount
    r = records(idx);
    if string(r.faultClass) == "Healthy"
        modePhrase = "no active failure mode detected";
    else
        modePhrase = "active failure mode " + friendlyFailureMode(r.faultClass);
    end
    parts(idx) = sprintf(['%s engine %s, %s, operational state %s, ' ...
        'remaining useful life %s, health indicator %.3f, fault classifier model confidence %.1f%%'], ...
        ordinalWord(idx), string(r.engineID), modePhrase, friendlyOpState(r.opState), ...
        formatRUL(r.rul), r.healthIndicator, r.classifierConfidence);
end
text = strjoin(parts, '; ') + ".";
end

function text = ordinalWord(idx)
words = ["first", "second", "third", "fourth", "fifth", "sixth"];
if idx <= numel(words)
    text = words(idx);
else
    text = string(idx);
end
end

function text = friendlyFailureMode(value)
value = string(value);
if value == "All"
    text = "all monitored failure modes";
else
    text = value;
end
end

function text = friendlyOpState(value)
value = string(value);
switch value
    case "Departure 0-2h"
        text = "scheduled for departure within 2 hours";
    case "Departure 2-6h"
        text = "scheduled for departure in 2 to 6 hours";
    case "Maintenance"
        text = "in maintenance";
    otherwise
        text = value;
end
end

function audit = buildAudit(finalText, toolResult, responseKind)
requiredFacts = requiredFactsFor(toolResult, responseKind);
missingFacts = strings(0, 1);
for idx = 1:numel(requiredFacts)
    if ~contains(finalText, requiredFacts(idx), 'IgnoreCase', true)
        missingFacts(end + 1, 1) = requiredFacts(idx); %#ok<AGROW>
    end
end

audit = struct( ...
    'stage', "deterministic_summary", ...
    'responseKind', responseKind, ...
    'usedLLMForFinalResponse', false, ...
    'requiredFacts', requiredFacts, ...
    'missingFacts', missingFacts, ...
    'finalResponseMatchesToolOutput', isempty(missingFacts));
end

function facts = requiredFactsFor(r, responseKind)
switch responseKind
    case "fleet"
        facts = string([ ...
            r.nTotal, r.nHealthy, r.nDegrading, r.nCritical, ...
            r.nEarlyFailure, r.nMaintenance]);
        facts(end + 1) = sprintf('%.3f', r.avgHI);
    case "clusters"
        facts = string([r.nHealthy, r.nDegrading, r.nCritical, ...
            r.nEarlyFailure, r.nMaintenance, r.operatingStates.Airborne]);
    case {"operating_state_count", "operating_state_list"}
        facts = string([r.count, r.nTotal]);
        facts(end + 1) = string(r.opState);
    case {"top_risk", "degrading", "critical", "early_failure"}
        if responseKind == "top_risk" && isfield(r, 'nCritical')
            facts = string(r.nCritical);
        else
            facts = string([getFieldOrDefault(r, 'count', numel(r.engines)), r.nTotal]);
        end
        if isfield(r, 'engineRecords') && ~isempty(r.engineRecords)
            facts(end + 1) = string(r.engineRecords(1).engineID);
        elseif ~isempty(r.engines)
            facts(end + 1) = extractBefore(string(r.engines(1)), " ");
        end
    case "highest_risk"
        if isfield(r, 'engineID')
            facts = [string(r.engineID), string(r.faultClass), ...
                sprintf('%.3f', r.healthIndicator), sprintf('%.1f', r.confidence)];
        else
            facts = string(getFieldOrDefault(r, 'count', 0));
        end
    case "engine"
        facts = [string(r.engineID), string(r.faultClass), friendlyOpState(r.opState), ...
            upper(string(r.status)), sprintf('%.3f', r.healthIndicator), ...
            sprintf('%.1f', r.confidence)];
        if isfinite(r.rul)
            facts(end + 1) = string(round(r.rul));
        else
            facts(end + 1) = "--";
        end
    otherwise
        facts = strings(0, 1);
end
facts = facts(:);
end

function value = getFieldOrDefault(s, fieldName, defaultValue)
if isstruct(s) && isfield(s, fieldName)
    value = s.(fieldName);
else
    value = defaultValue;
end
end

function text = formatRUL(rul)
if isfinite(rul)
    text = sprintf('%d cycles', round(rul));
else
    text = '--';
end
end

function text = formatTick(tickIndex)
if isnumeric(tickIndex) && isfinite(tickIndex)
    text = sprintf('%d', tickIndex);
else
    text = '--';
end
end
