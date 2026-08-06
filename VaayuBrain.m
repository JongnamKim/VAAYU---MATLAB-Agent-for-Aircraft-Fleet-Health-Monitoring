function VaayuBrain()
% VaayuBrain - Iron Man JARVIS-style 3D Neural Sphere
% Reacts to microphone input with dynamic particle animations
% Part of the MATLAB ecosystem

%% ── UI SETUP ──────────────────────────────────────────────────────────────
screenSz = get(0, 'ScreenSize');
figW = screenSz(3); figH = screenSz(4) - 40;
fig = uifigure('Name', 'VAAYU // NEURAL INTERFACE', 'Position', [1 40 figW figH], ...
    'Color', [0 0 0], 'Resize', 'on');
fig.WindowState = 'maximized';

% ── 3D Axes (main brain sphere) ─────────────────────────────────────────
ax = uiaxes(fig, 'Position', [0 110 figW figH-110]);
ax.Color        = [0 0 0];
ax.XColor       = 'none';
ax.YColor       = 'none';
ax.ZColor       = 'none';
ax.GridColor    = 'none';
ax.Box          = 'off';
ax.DataAspectRatio = [1 1 1];
ax.XLim = [-1.6 1.6];
ax.YLim = [-1.6 1.6];
ax.ZLim = [-1.6 1.6];
view(ax, 35, 20);
hold(ax, 'on');

% ── Disable ALL interactivity ────────────────────────────────────────────
disableDefaultInteractivity(ax);
ax.Toolbar.Visible      = 'off';
ax.Interactions         = [];
ax.HitTest              = 'off';
ax.PickableParts        = 'none';

% ── Status / ticker label ────────────────────────────────────────────────
statusLbl = uilabel(fig, ...
    'Position', [0 180 figW 25], ...
    'Text',     '▸  SYSTEM IDLE  //  AWAITING INPUT', ...
    'FontName',  'Courier New', ...
    'FontSize',  16, ...
    'FontColor', [0 1 1], ...
    'BackgroundColor', [0 0 0], ...
    'HorizontalAlignment', 'center');

volumeTrackW = max(260, round(figW * 0.28));
volumeTrack = uipanel(fig, ...
    'Position', [round((figW - volumeTrackW) / 2) 155 volumeTrackW 10], ...
    'BackgroundColor', [0.06 0.08 0.10], ...
    'BorderType', 'line', ...
    'HighlightColor', [0.15 0.30 0.34], ...
    'Visible', 'off');
volumeFill = uipanel(volumeTrack, ...
    'Position', [1 1 1 8], ...
    'BackgroundColor', [1.00 0.72 0.12], ...
    'BorderType', 'none', ...
    'Visible', 'off');

% ── Name labels ──────────────────────────────────────────────────────────
uilabel(fig, ...
    'Position', [0 100 figW/2 25], ...
    'Text',     'V.A.A.Y.U', ...
    'FontName',  'Courier New', ...
    'FontSize',  22, ...
    'FontWeight','bold', ...
    'FontColor', [1 1 0], ...
    'BackgroundColor', [0 0 0], ...
    'HorizontalAlignment', 'center');

uilabel(fig, ...
    'Position', [0 70 figW/2 33], ...
    'Text',     'Voice-assisted Agent for Aircraft Yield & Uptime', ...
    'FontName',  'Courier New', ...
    'FontSize',  14, ...
    'FontWeight','bold', ...
    'FontColor', [1 1 0], ...
    'BackgroundColor', [0 0 0], ...
    'HorizontalAlignment', 'center');

uilabel(fig, ...
    'Position', [figW/2 100 figW/2 25], ...
    'Text',     'NEURAL CORE  v1.0', ...
    'FontName',  'Courier New', ...
    'FontSize',  14, ...
    'FontColor', [0.4 0.8 1], ...
    'BackgroundColor', [0 0 0], ...
    'HorizontalAlignment', 'center');

% ── Chat ribbon ──────────────────────────────────────────────────────────
chatW = figW - 230;
chatField = uieditfield(fig, 'text', ...
    'Position', [15 12 chatW 36], ...
    'FontName',  'Courier New', ...
    'FontSize',  12, ...
    'FontColor', [0.9 0.95 1], ...
    'BackgroundColor', [0.08 0.08 0.15], ...
    'Placeholder', 'Type a message for VAAYU...');

sendBtn = uibutton(fig, 'push', ...
    'Text',     'SPEAK', ...
    'Position', [chatW+25 12 90 36], ...
    'FontName',  'Courier New', ...
    'FontSize',  12, ...
    'FontWeight','bold', ...
    'FontColor', [0 0 0], ...
    'BackgroundColor', [1 0.75 0.1]);

% ── Mic button ───────────────────────────────────────────────────────────
btn = uibutton(fig, 'push', ...
    'Text',     '⬤  MIC', ...
    'Position', [chatW+125 12 100 36], ...
    'FontName',  'Courier New', ...
    'FontSize',  12, ...
    'FontWeight','bold', ...
    'FontColor', [0 0 0], ...
    'BackgroundColor', [0 1 1]);

%% Neural sphere animator
rootFolder = fileparts(mfilename('fullpath'));
addpath(fullfile(rootFolder, 'helperFunctions'));
neuralAnimator = createVaayuNeuralSphereAnimator(ax);
%% ── WHISPER SPEECH CLIENT ─────────────────────────────────────────────────
drawnow;
statusLbl.Text      = '▸  LOADING WHISPER MODEL  //  PLEASE WAIT';
statusLbl.FontColor = [0.6 0.4 1];
drawnow;
whisperLoadTic = tic;
whisperClient = speechClient("whisper","model","small",ExecutionEnvironment="gpu");
fprintf('[VAAYU startup] Whisper model loaded in %.2f seconds.\n', toc(whisperLoadTic));

%% ── OLLAMA LLM (local Gemma) ─────────────────────────────────────────────
statusLbl.Text      = '▸  WARMING UP LOCAL LLM  //  GEMMA 4B';
statusLbl.FontColor = [0.6 0.4 1];
drawnow;
localLlmLoadTic = tic;
vaayuModel = createVaayuAgentModel();
fprintf('[VAAYU startup] Local LLM model configured in %.2f seconds.\n', toc(localLlmLoadTic));
chatHistory = messageHistory;           % rolling conversation buffer
turbofanDiagnostics = [];
activeView = "neural";
statusLbl.Text      = '▸  SYSTEM IDLE  //  AWAITING INPUT';
statusLbl.FontColor = [0 1 1];

%% ── .NET SPEECH SYNTHESIZER ──────────────────────────────────────────────
NET.addAssembly('System.Speech');
synth = System.Speech.Synthesis.SpeechSynthesizer();
synth.Rate = 1;
addlistener(synth, 'SpeakStarted',   @(~,~) markSpeaking(true));
addlistener(synth, 'SpeakCompleted', @(~,~) markSpeaking(false));

%% ── STATE VARIABLES ───────────────────────────────────────────────────────
isRecording  = false;
isSpeaking   = false;
wasSpeaking  = false;
speakVolume  = 100;
recObj       = audiorecorder(22050, 16, 1);

%% ── BUTTON CALLBACKS & KEY BINDINGS ──────────────────────────────────────
btn.ButtonPushedFcn       = @(~,~) toggleMic();
sendBtn.ButtonPushedFcn   = @(~,~) onSendChat();
chatField.ValueChangedFcn = @(~,~) onSendChat();
fig.WindowKeyPressFcn     = @(~,evt) onKeyPress(evt);
fig.WindowKeyReleaseFcn   = @(~,evt) onKeyRelease(evt);

%% ── ANIMATION TIMER ──────────────────────────────────────────────────────
timerObj = timer( ...
    'ExecutionMode', 'fixedSpacing', ...
    'Period',        0.04, ...
    'TimerFcn',      @updateScene);
start(timerObj);
warmLocalLlmAsync();

fig.CloseRequestFcn = @(~,~) cleanup();

%% ════════════════════════════════════════════════════════════════════════
%  INNER FUNCTIONS
%% ════════════════════════════════════════════════════════════════════════

    function toggleMic()
        if ~isRecording, startMic(); else, stopMic(); end
    end

    function startMic()
        if isRecording, return; end
        record(recObj);
        pause(0.12);
        isRecording = true;
        btn.Text             = '◼  MIC ON';
        btn.FontColor        = [1 1 1];
        btn.BackgroundColor  = [0.8 0.1 0.1];
        statusLbl.Text = '▸  LISTENING  //  AUDIO STREAM ACTIVE';
        statusLbl.FontColor  = [0.2 1 0.4];
    end

    function stopMic()
        if ~isRecording, return; end
        stop(recObj);
        isRecording = false;
        btn.Text             = '⬤  MIC';
        btn.FontColor        = [0 0 0];
        btn.BackgroundColor  = [0 1 1];

        audioData = getaudiodata(recObj);
        if numel(audioData) < 4410
            statusLbl.Text = '▸  SYSTEM IDLE  //  AWAITING INPUT';
            statusLbl.FontColor = [0 1 1];
            return;
        end

        statusLbl.Text      = '▸  TRANSCRIBING  //  WHISPER PROCESSING';
        statusLbl.FontColor = [0.6 0.4 1];
        drawnow;

        transcript = speech2text(audioData, recObj.SampleRate, Client=whisperClient);
        if istable(transcript)
            spokenText = strjoin(transcript.text);
        else
            spokenText = strjoin(string(transcript));
        end
        spokenText = normalizeTranscript(spokenText);

        if strtrim(spokenText) == ""
            statusLbl.Text = '▸  SYSTEM IDLE  //  NO SPEECH DETECTED';
            statusLbl.FontColor = [0 1 1];
            return;
        end

        chatField.Value = char(spokenText);
        processQuery(spokenText);
    end

    function onKeyPress(evt)
        if strcmp(evt.Key, 'space') && ~isa(fig.CurrentObject, 'matlab.ui.control.EditField')
            startMic();
        end
    end

    function onKeyRelease(evt)
        if strcmp(evt.Key, 'space') && ~isa(fig.CurrentObject, 'matlab.ui.control.EditField')
            stopMic();
        end
    end

    function onSendChat()
        txt = strtrim(chatField.Value);
        if isempty(txt), return; end
        chatField.Value = '';
        processQuery(string(txt));
    end

    function processQuery(queryText)
        statusLbl.Text      = '▸  THINKING  //  LOCAL LLM PROCESSING';
        statusLbl.FontColor = [0.6 0.4 1];
        drawnow;

        auditRecord = struct( ...
            'schemaVersion', 1, ...
            'userQuery', queryText, ...
            'route', struct(), ...
            'toolExecution', struct(), ...
            'toolOutput', struct(), ...
            'finalResponse', "", ...
            'finalResponseAudit', struct(), ...
            'auditLogPath', "");

        [resp, chatHistory, routeAudit] = vaayuRespond(vaayuModel, queryText, chatHistory);
        auditRecord.route = routeAudit;

        if resp.type == "chat"
            auditRecord.finalResponse = resp.speak;
            logVaayuInteraction(auditRecord);
            showNeuralCore();
            speakVolume = 50;
            statusLbl.Text = '▸  SPEAKING  //  VOICE OUTPUT ACTIVE';
            statusLbl.FontColor = [1 0.75 0.2];
            speakText(synth, resp.speak, speakVolume);

        elseif resp.type == "tool"
            speakVolume = 50;
            statusLbl.Text = '▸  SPEAKING  //  VOICE OUTPUT ACTIVE';
            statusLbl.FontColor = [1 0.75 0.2];
            speakText(synth, resp.speak, speakVolume);

            statusLbl.Text = sprintf('▸  EXECUTING  //  %s', upper(resp.tool));
            statusLbl.FontColor = [0.6 0.4 1];
            drawnow;

            [toolResult, toolAudit] = vaayuTools.executeFleetTool(resp.tool, resp.params);
            auditRecord.toolExecution = toolAudit;
            auditRecord.toolOutput = toolResult;
            if isAssetSpecificDiagnostic(toolResult)
                showTurbofanDiagnostics(queryText, toolResult);
            else
                showNeuralCore();
            end

            statusLbl.Text = '▸  SUMMARIZING  //  LOCAL LLM PROCESSING';
            statusLbl.FontColor = [0.6 0.4 1];
            drawnow;

            summary = vaayuSummarize(vaayuModel, queryText, toolResult);
            auditRecord.finalResponse = summary.speak;
            auditRecord.finalResponseAudit = summary.audit;
            logVaayuInteraction(auditRecord);

            while isSpeaking, pause(0.1); end
            speakVolume = 50;
            statusLbl.Text = '▸  SPEAKING  //  VOICE OUTPUT ACTIVE';
            statusLbl.FontColor = [1 0.75 0.2];
            speakText(synth, summary.speak, speakVolume);
        end
    end

    function updateScene(~, ~)
        if activeView ~= "neural"
            drawnow limitrate;
            return;
        end

        frame = neuralAnimator.update(isSpeaking, isRecording, recObj, speakVolume);

        if wasSpeaking && ~isSpeaking
            statusLbl.Text = '>  SYSTEM IDLE  //  AWAITING INPUT';
            statusLbl.FontColor = [0 1 1];
        end
        wasSpeaking = isSpeaking;

        amp = frame.Amplitude;
        if isSpeaking
            updateVolumeBar(amp, true, [1.00 0.72 0.12]);
            statusLbl.Text = '>  SPEAKING  //  VOICE OUTPUT ACTIVE';
            statusLbl.FontColor = [1 0.75 0.2];
        elseif isRecording
            updateVolumeBar(amp, true, [0.15 1.00 0.55]);
            statusLbl.Text = sprintf('>  AUDIO LEVEL  %.0f%%  //  NEURAL ACTIVITY: %s', ...
                amp*100, frame.ActivityLabel);
        else
            updateVolumeBar(0, false, [1.00 0.72 0.12]);
        end

        drawnow limitrate;
    end

    function updateVolumeBar(amp, isVisible, color)
        if isVisible
            volumeTrack.Visible = 'on';
            volumeFill.Visible = 'on';
        else
            volumeTrack.Visible = 'off';
            volumeFill.Visible = 'off';
        end
        volumeFill.BackgroundColor = color;
        if isVisible
            trackPos = volumeTrack.Position;
            fillW = max(1, round((trackPos(3) - 2) * min(max(amp, 0), 1)));
            volumeFill.Position = [1 1 fillW 8];
        end
    end

    function markSpeaking(val)
        isSpeaking = val;
    end

    function cleanup()
        try
            stop(timerObj);
            delete(timerObj);
        catch
        end
        try
            stop(recObj);
        catch
        end
        try
            synth.SpeakAsyncCancelAll();
            synth.Dispose();
        catch
        end
        try
            neuralAnimator.delete();
        catch
        end
        try
            delete(turbofanDiagnostics);
        catch
        end
        delete(fig);
    end

    function warmLocalLlmAsync()
        if ~ispc
            return;
        end

        [status, ~] = system('where ollama >NUL 2>NUL');
        if status ~= 0
            warning("VAAYU:OllamaUnavailable", ...
                "Ollama CLI was not found on PATH; local LLM warm-up was skipped.");
            return;
        end

        [status, msg] = system('start "" /B ollama run gemma3:4b "Hello" >NUL 2>NUL');
        if status ~= 0
            warning("VAAYU:OllamaWarmupSkipped", ...
                "Could not start background LLM warm-up: %s", strtrim(msg));
        end
    end

    function showNeuralCore()
        if activeView == "neural"
            return;
        end

        activeView = "neural";
        ax.Visible = "on";
        neuralAnimator.setVisible(true);

        try
            if ~isempty(turbofanDiagnostics) && isvalid(turbofanDiagnostics)
                delete(turbofanDiagnostics);
            end
        catch
        end
        turbofanDiagnostics = [];
    end

    function showTurbofanDiagnostics(queryText, toolResult)
        try
            showNeuralCore();
            mode = TurbofanDiagnosticsWindow.modeFromToolResult(toolResult);
            if mode == "none"
                mode = TurbofanDiagnosticsWindow.failureModeFromText(queryText);
            end

            if isempty(turbofanDiagnostics) || ~isvalid(turbofanDiagnostics) || ~turbofanDiagnostics.isOpen()
                turbofanDiagnostics = TurbofanDiagnosticsWindow( ...
                    "RootFolder", rootFolder, ...
                    "Mode", mode, ...
                    "Position", [80 80 1120 700], ...
                    "AlwaysOnTop", false);
            end
            turbofanDiagnostics.showMode(mode);
        catch ME
            activeView = "neural";
            ax.Visible = "on";
            neuralAnimator.setVisible(true);
            warning("VAAYU:TurbofanDiagnosticsUnavailable", ...
                "Could not show turbofan diagnostics: %s", ME.message);
        end
    end

    function tf = isAssetSpecificDiagnostic(toolResult)
        tf = isstruct(toolResult) && ...
            isfield(toolResult, "engineID") && ...
            strlength(string(toolResult.engineID)) > 0 && ...
            ~(isfield(toolResult, "error") && logical(toolResult.error));
    end

    function text = normalizeTranscript(text)
        text = string(text);
        text = regexprep(text, '^\s*(Why you|Wei u|Wai you|Way you|Y U|Vayu)\b', 'VAAYU', 'ignorecase');
        text = regexprep(text, '\bH\s*I\b', 'health indicator', 'ignorecase');
        text = regexprep(text, '\s+', ' ');
        text = strip(text);
    end

end
