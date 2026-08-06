model = ollamaChat("gemma3:4b", ...
    "You are a helpful tool calling AI assistant. You will get a " + ...
    "prompt for each question, and have to return with the exact tool calling json." + ...
    "Return ONLY JSON. Do not explain. Do not add text.", ...
    TimeOut=100); % phi, mistral, wizardlm2 gpt-oss:20b, gemma3:4b

%% 
% transcript = "check engine 23 health";
transcript = "which engines are degrading or near maintenance ?";

tic
toolReq = getToolRequest(model, transcript);
toc
toolReq.tool
toolReq.engine_id

% result = executeTool(client, toolReq); % MATLAB MCP HTTP Client
% 
% final = summarizeResponse(model, transcript, result);



%% 



%% 
% Figure out which tool to call with a LLM 
function toolRequest = getToolRequest(model, text)

prompt = [
"Convert the user request into a JSON tool call." + newline + ...
"ONLY return valid JSON. No explanation." + newline + newline + ...
"Available tools:" + newline + ...
"- analyze_engine(engine_id)" + newline + ...
"- predict_failure(engine_id)" + newline + ...
"- explain_engine(engine_id)" + newline + newline + ...
"- check_degrading_engines(engine_id)" + newline + ...
"Format:" + newline + ...
"{""tool"":""name"",""engine_id"":number}" + newline + newline + ...
"User: " + text
];

raw = generate(model, prompt);
raw = strip(raw);

% Clean markdown if any
raw = regexprep(raw, '```json|```', '');

toolRequest = jsondecode(raw);

end

% Tool Execution - To be done by MATLAB
function result = executeTool(client, toolRequest)

switch toolRequest.tool

    case "analyze_engine"
        result = callTool(client, "analyze_engine", ...
            "engine_id", toolRequest.engine_id);

    case "predict_failure"
        result = callTool(client, "predict_failure", ...
            "engine_id", toolRequest.engine_id);

    case "explain_engine"
        result = callTool(client, "explain_engine", ...
            "engine_id", toolRequest.engine_id);

    case "check_degrading_engines"
        result = callTool(client, "check_degrading_engines", ...
            "engine_id", toolRequest.engine_id);

    otherwise
        result.message = "Unknown tool";
end

end

% Tool Response summarization by the LLM
function final = summarizeResponse(model, userText, toolResult)

prompt = [
"User query: " + userText + newline + ...
"Tool result: " + jsonencode(toolResult) + newline + ...
"Respond in max 2 sentences. Be concise."
];

final = generate(model, prompt);

end
