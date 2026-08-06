function model = createVaayuAgentModel()
%createVaayuAgentModel Build the VAAYU LLM that decides chat responses or tool calls.
arguments (Output)
    % Ollama chat model configured for JSON agent tool selection
    model (1,1) ollamaChat
end

model = createVaayuRouterModel();
end
