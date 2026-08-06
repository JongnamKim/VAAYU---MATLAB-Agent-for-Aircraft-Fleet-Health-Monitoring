function reply = askOllama(model, userMessage)
arguments
    model
    userMessage (1,1) string
end

try
    raw = generate(model, userMessage);
    reply = strtrim(string(raw));
    if reply == ""
        reply = "I didn't catch a valid response. Try again, Boss.";
    end
catch ex
    reply = "Local model error: " + string(ex.message);
end
end
