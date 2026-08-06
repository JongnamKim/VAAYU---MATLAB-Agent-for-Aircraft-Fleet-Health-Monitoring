classdef TurbofanDiagnosticsWindow < handle
    %TURBOFANDIAGNOSTICSWINDOW Hosts the turbofan WebGL diagnostic scene.
    %
    % This uses MATLAB's Chromium webwindow instead of uihtml because uihtml
    % can load the DOM but does not present WebGL graphics reliably here.

    properties (Access = private)
        RootFolder (1,1) string
        HtmlFile (1,1) string
        Port (1,1) double
        ServerProcess
        Window
        CurrentMode (1,1) string = "none"
        IsClosed (1,1) logical = false
    end

    methods
        function obj = TurbofanDiagnosticsWindow(varargin)
            args = parseInputs(varargin{:});

            obj.RootFolder = string(args.RootFolder);
            obj.HtmlFile = fullfile(obj.RootFolder, "turbofan_3d_failure_diagnostics.html");
            assert(isfile(obj.HtmlFile), "Cannot find turbofan diagnostics HTML: %s", obj.HtmlFile);

            obj.Port = args.Port;
            if obj.Port == 0
                obj.Port = findAvailablePort();
            end
            obj.startServer();
            obj.openWindow(args.Mode, args.Position, args.AlwaysOnTop, args.View);
        end

        function showMode(obj, mode)
            if obj.IsClosed
                return
            end

            mode = TurbofanDiagnosticsWindow.normalizeFailureMode(mode);
            obj.CurrentMode = mode;
            obj.ensureWindow();
            obj.Window.bringToFront();

            state = struct("mode", mode, "config", TurbofanDiagnosticsWindow.runtimeConfigForMode(mode));
            js = "if (!window.setTurbofanDiagnosticsState) { throw new Error('Turbofan diagnostics bridge is not ready.'); }" + ...
                "window.setTurbofanDiagnosticsState(" + jsonencode(state) + ");";
            try
                obj.Window.executeJS(char(js), 5);
            catch
                obj.Window.URL = obj.urlForMode(mode);
            end
        end

        function showForResult(obj, queryText, toolResult)
            mode = TurbofanDiagnosticsWindow.modeFromToolResult(toolResult);
            if mode == "none"
                mode = TurbofanDiagnosticsWindow.failureModeFromText(queryText);
            end
            obj.showMode(mode);
        end

        function img = screenshot(obj, filename)
            obj.ensureWindow();
            pause(0.5);
            img = obj.Window.getScreenshot();
            if nargin > 1 && strlength(string(filename)) > 0
                imwrite(img, filename);
            end
        end

        function delete(obj)
            obj.close();
        end

        function close(obj)
            if obj.IsClosed
                return
            end
            obj.IsClosed = true;

            try
                if ~isempty(obj.Window)
                    obj.Window.close();
                    delete(obj.Window);
                end
            catch
            end

            try
                if ~isempty(obj.ServerProcess) && ~obj.ServerProcess.HasExited
                    obj.ServerProcess.Kill();
                    obj.ServerProcess.WaitForExit(1500);
                end
            catch
            end
        end

        function tf = isOpen(obj)
            tf = ~obj.IsClosed && ~isempty(obj.Window);
            if tf
                try
                    tf = obj.Window.isWindowValid;
                catch
                    tf = false;
                end
            end
        end
    end

    methods (Static)
        function mode = normalizeFailureMode(mode)
            key = lower(strtrim(string(mode)));
            key = replace(key, "-", " ");
            key = replace(key, "_", " ");
            key = regexprep(key, "\s+", " ");

            if key == "" || key == "healthy" || key == "nominal" || key == "normal"
                mode = "none";
            elseif contains(key, "hpc") && contains(key, "lpc")
                mode = "hpc_lpc";
            elseif contains(key, "hpt") && contains(key, "lpt")
                mode = "hpt_lpt";
            elseif contains(key, "fan")
                mode = "fan";
            elseif contains(key, "hpc")
                mode = "hpc";
            elseif contains(key, "lpc")
                mode = "hpc_lpc";
            elseif contains(key, "hpt")
                mode = "hpt";
            elseif contains(key, "lpt")
                mode = "lpt";
            elseif key == "all" || contains(key, "global") || contains(key, "all rotor")
                mode = "all";
            else
                mode = "none";
            end
        end

        function mode = modeFromToolResult(result)
            mode = "none";
            if ~isstruct(result)
                return
            end

            candidates = strings(0, 1);
            fields = ["faultClass", "failureMode", "mode", "healthState", "message"];
            for field = fields
                if isfield(result, field)
                    candidates(end + 1, 1) = string(result.(field)); %#ok<AGROW>
                end
            end

            if isfield(result, "topRisk")
                candidates = [candidates; string(result.topRisk(:))];
            end
            if isfield(result, "engines")
                candidates = [candidates; string(result.engines(:))];
            end

            for idx = 1:numel(candidates)
                mode = TurbofanDiagnosticsWindow.failureModeFromText(candidates(idx));
                if mode ~= "none"
                    return
                end
            end
        end

        function mode = failureModeFromText(text)
            txt = lower(string(text));
            if contains(txt, "hpc") && contains(txt, "lpc")
                mode = "hpc_lpc";
            elseif contains(txt, "hpt") && contains(txt, "lpt")
                mode = "hpt_lpt";
            elseif contains(txt, "fan")
                mode = "fan";
            elseif contains(txt, "hpc")
                mode = "hpc";
            elseif contains(txt, "hpt")
                mode = "hpt";
            elseif contains(txt, "lpt")
                mode = "lpt";
            elseif contains(txt, "all") && (contains(txt, "failure") || contains(txt, "rotor"))
                mode = "all";
            else
                mode = "none";
            end
        end

        function config = runtimeConfigForMode(mode)
            mode = TurbofanDiagnosticsWindow.normalizeFailureMode(mode);
            view = TurbofanDiagnosticsWindow.viewForMode(mode);
            opacity = TurbofanDiagnosticsWindow.coreFlowOpacityForMode(mode);
            config = struct("view", view, "flowOpacity", struct("core", opacity));
        end

        function view = viewForMode(mode)
            mode = TurbofanDiagnosticsWindow.normalizeFailureMode(mode);
            target = [-1.044 -0.399 -0.569];
            up = [0.000 1.000 0.000];

            switch mode
                case {"hpc", "hpc_lpc"}
                    position = [-4.472 2.273 10.579];
                case {"hpt", "hpt_lpt"}
                    position = [1.963 1.258 11.319];
                case {"lpt", "all"}
                    position = [6.811 2.780 9.425];
                otherwise
                    position = [-8.300 1.500 7.300];
            end

            view = struct("position", position, "target", target, "up", up);
        end

        function opacity = coreFlowOpacityForMode(mode)
            mode = TurbofanDiagnosticsWindow.normalizeFailureMode(mode);
            switch mode
                case {"hpt", "hpt_lpt", "lpt", "all"}
                    opacity = 0.3;
                otherwise
                    opacity = 0.7;
            end
        end
    end

    methods (Access = private)
        function startServer(obj)
            maxAttempts = 25;
            for attempt = 1:maxAttempts
                if respondsWithViewer(obj.Port)
                    return
                end

                if ~isPortAvailable(obj.Port)
                    obj.Port = obj.Port + 1;
                    continue
                end

                args = sprintf('-m http.server %d --bind 127.0.0.1', obj.Port);
                psi = System.Diagnostics.ProcessStartInfo("python", args);
                psi.WorkingDirectory = char(obj.RootFolder);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                obj.ServerProcess = System.Diagnostics.Process.Start(psi);

                deadline = tic;
                while toc(deadline) < 5
                    if respondsWithViewer(obj.Port)
                        return
                    end
                    pause(0.1);
                end

                if ~isempty(obj.ServerProcess) && ~obj.ServerProcess.HasExited
                    obj.ServerProcess.Kill();
                    obj.ServerProcess.WaitForExit(1500);
                end
                obj.Port = obj.Port + 1;
            end
            error("TurbofanDiagnosticsWindow:ServerStartFailed", ...
                "Local HTML server did not respond on or after port %d.", obj.Port - maxAttempts);
        end

        function openWindow(obj, mode, position, alwaysOnTop, view)
            mode = TurbofanDiagnosticsWindow.normalizeFailureMode(mode);
            obj.CurrentMode = mode;
            if nargin < 5 || isempty(view)
                view = TurbofanDiagnosticsWindow.viewForMode(mode);
            end
            obj.Window = matlab.internal.webwindow(obj.urlForMode(mode, view), "Position", position);
            obj.Window.Title = "VAAYU Turbofan Failure Diagnostics";
            obj.Window.setResizable(true);
            obj.Window.setAlwaysOnTop(alwaysOnTop);
            obj.Window.CustomWindowClosingCallback = @(~, ~) obj.close();
            obj.Window.show();
        end

        function ensureWindow(obj)
            if isempty(obj.Window) || ~obj.Window.isWindowValid
                obj.openWindow(obj.CurrentMode, [80 80 980 640], false, []);
            end
        end

        function url = urlForMode(obj, mode, view)
            mode = TurbofanDiagnosticsWindow.normalizeFailureMode(mode);
            coreFlowOpacity = TurbofanDiagnosticsWindow.coreFlowOpacityForMode(mode);
            url = char("http://127.0.0.1:" + obj.Port + ...
                "/turbofan_3d_failure_diagnostics.html?mode=" + mode + ...
                "&embed=1&streamline_opacity=0.1&core_flow_opacity=" + coreFlowOpacity + ...
                "&bypass_flow_opacity=0.15");
            if nargin >= 3 && ~isempty(view)
                url = url + "&view=" + encodeUrlComponent(jsonencode(view));
            end
        end
    end
end

function args = parseInputs(varargin)
parser = inputParser;
parser.addParameter("RootFolder", fileparts(mfilename("fullpath")));
parser.addParameter("Mode", "none");
parser.addParameter("Port", 8000);
parser.addParameter("Position", [80 80 980 640]);
parser.addParameter("View", []);
parser.addParameter("AlwaysOnTop", false);
parser.parse(varargin{:});
args = parser.Results;
end

function encoded = encodeUrlComponent(text)
encoded = string(java.net.URLEncoder.encode(string(text), "UTF-8"));
encoded = replace(encoded, "+", "%20");
end

function port = findAvailablePort()
listener = System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, int32(0));
listener.Start();
endpoint = listener.LocalEndpoint;
port = double(endpoint.Port);
listener.Stop();
end

function tf = respondsWithViewer(port)
try
    html = webread("http://127.0.0.1:" + port + "/turbofan_3d_failure_diagnostics.html?embed=1");
    tf = contains(string(html), "Interactive 3D two-spool turbofan model");
catch
    tf = false;
end
end

function tf = isPortAvailable(port)
listener = [];
try
    listener = System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, int32(port));
    listener.Start();
    tf = true;
catch
    tf = false;
end

if ~isempty(listener)
    listener.Stop();
end
end
