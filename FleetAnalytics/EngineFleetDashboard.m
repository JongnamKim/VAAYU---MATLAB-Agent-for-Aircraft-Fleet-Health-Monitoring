function EngineFleetDashboard(mode)
%% Turbofan Engine Fleet Health Monitoring Dashboard
% Real-time streaming dashboard powered by monitorEngineFleet microservice
% Loads shuffledFleetData.mat, streams 9 engines/tick through analytics

if nargin < 1 || strlength(string(mode)) == 0
    mode = "Online";
end
mode = validatestring(char(string(mode)), {'Online', 'Offline'}, mfilename, 'mode', 1);
mode = string(mode);

%% Create Main Figure
fig = uifigure('Name', 'TurboPulse — Engine Fleet Health Monitor', ...
    'Position', [50 50 1920 1000], 'Color', [0.08 0.08 0.10], ...
    'WindowState', 'maximized');

app = struct();
app.fig = fig;
app.nEngines = 99;
app.tickIndex = 0;
app.basePath = fileparts(mfilename('fullpath'));
app.snapshotPath = fullfile(app.basePath, 'jarvisFleetSnapshot.mat');
app.microserviceOptions = weboptions('MediaType', 'application/json', 'Timeout', 60);
app.healthOptions = weboptions('Timeout', 3);
app.serviceEndpoint = "Local";
app.serviceEndpoints = createServiceEndpointCatalog();
app = configureServiceEndpoint(app, app.serviceEndpoint);
app.dashboardMode = mode;
app.isOfflineMode = mode == "Offline";
app.refreshPeriod = 10;
app.reconnectPeriod = 60;
app.serviceAvailable = false;
app.connectionMessage = "Checking microservice connection";
app.routeDisplayMode = "2D";
app.routeGlobeEnabled = false;

app.failureModes = ["HPT","LPT","HPT + LPT","Fan","HPC","HPC + LPC","All"];
app.stateNames = ["Airborne", "Just Landed", "Departure 0-2h", ...
                  "Departure 2-6h", "Ground Idle", "Maintenance"];

%% Load Fleet Data
app = loadFleetData(app, fig);

%% Main Grid Layout
app.mainGrid = uigridlayout(fig, [1 3]);
app.mainGrid.ColumnWidth = {'1.2x', '2.5x', '1.3x'};
app.mainGrid.Padding = [8 8 8 8];
app.mainGrid.ColumnSpacing = 8;
app.mainGrid.BackgroundColor = [0.08 0.08 0.10];

%% LEFT PANEL — KPIs + Controls + Risk List
leftPanel = uipanel(app.mainGrid, 'BorderType', 'none', ...
    'BackgroundColor', [0.08 0.08 0.10]);
leftPanel.Layout.Column = 1;

leftGrid = uigridlayout(leftPanel, [4 1]);
leftGrid.RowHeight = {200, 140, '1x', '1x'};
leftGrid.Padding = [0 0 0 0];
leftGrid.RowSpacing = 8;
leftGrid.BackgroundColor = [0.08 0.08 0.10];

app = buildKPIPanel(app, leftGrid);
app = buildControlPanel(app, leftGrid);
app = buildFlightClassPanel(app, leftGrid);
app = buildRiskSummaryPanel(app, leftGrid);

%% CENTER PANEL — Operational Cluster View
centerPanel = uipanel(app.mainGrid, 'BorderType', 'none', ...
    'BackgroundColor', [0.08 0.08 0.10]);
centerPanel.Layout.Column = 2;

centerGrid = uigridlayout(centerPanel, [2 1]);
centerGrid.RowHeight = {70, '1x'};
centerGrid.Padding = [0 0 0 0];
centerGrid.RowSpacing = 4;
centerGrid.BackgroundColor = [0.08 0.08 0.10];

app = buildTitleRibbon(app, centerGrid);
centerTabs = uitabgroup(centerGrid);
centerTabs.Layout.Row = 2;
app.centerTabs = centerTabs;
clusterTab = uitab(centerTabs, 'Title', 'Operational Clusters');
clusterTabGrid = uigridlayout(clusterTab, [1 1]);
clusterTabGrid.Padding = [0 0 0 0];
clusterTabGrid.BackgroundColor = [0.08 0.08 0.10];
app = buildClusterView(app, clusterTabGrid);

mapTab = uitab(centerTabs, 'Title', 'Airborne Route Map');
mapTabGrid = uigridlayout(mapTab, [1 1]);
mapTabGrid.Padding = [0 0 0 0];
mapTabGrid.RowSpacing = 0;
mapTabGrid.ColumnSpacing = 0;
mapTabGrid.BackgroundColor = [0.08 0.08 0.10];
app = buildRouteMap(app, mapTabGrid);
app.routeMapTab = mapTab;
app.routeMapNeedsRender = true;
centerTabs.SelectionChangedFcn = @(~,~) centerTabChanged(app.fig);

%% RIGHT PANEL — Selected Engine Detail
rightPanel = uipanel(app.mainGrid, 'BorderType', 'none', ...
    'BackgroundColor', [0.08 0.08 0.10]);
rightPanel.Layout.Column = 3;

rightGrid = uigridlayout(rightPanel, [2 1]);
rightGrid.RowHeight = {'1x', '1.2x'};
rightGrid.Padding = [0 0 0 0];
rightGrid.RowSpacing = 8;
rightGrid.BackgroundColor = [0.08 0.08 0.10];

app = buildEngineDetailPanel(app, rightGrid);
app = buildPlotPanel(app, rightGrid);

%% Store and Initial Render
app.cardHandles = containers.Map();
app.clusterGrids = gobjects(6, 1);
fig.UserData = app;
renderClusters(fig);
updateKPIs(fig);
updateSelectedEngine(fig);

app.centerPanel = centerPanel;
fig.UserData = app;

%% Start Streaming Timer
timerPeriod = app.refreshPeriod;
if ~app.serviceAvailable
    timerPeriod = app.reconnectPeriod;
end
app.streamTimer = timer('ExecutionMode', 'fixedSpacing', ...
    'Period', timerPeriod, 'TimerFcn', @(~,~) streamTick(fig));
fig.UserData = app;
persistDashboardSnapshot(app);
fig.CloseRequestFcn = @(~,~) cleanupDashboard(fig);

start(app.streamTimer);
end

function resumeState = loadDashboardResumeState(snapshotPath)
resumeState = [];
if ~isfile(snapshotPath)
    return;
end

snapshotData = load(snapshotPath, 'dashboardState');
if ~isfield(snapshotData, 'dashboardState')
    return;
end

candidate = snapshotData.dashboardState;
requiredFields = {'fleet', 'hiHistory', 'rulHistory', 'cycleHistory', 'tickIndex'};
if ~all(isfield(candidate, requiredFields))
    return;
end

if ~isfield(candidate, 'schemaVersion') || candidate.schemaVersion < 3 || ...
        ~ismember('RUL', candidate.fleet.Properties.VariableNames)
    return;
end

resumeState = candidate;
end

function app = applyDashboardResumeState(app, resumeState, flightClasses)
app.fleet = resumeState.fleet;
app.hiHistory = resumeState.hiHistory;
app.rulHistory = resumeState.rulHistory;
app.cycleHistory = resumeState.cycleHistory;
if isfield(resumeState, 'tickHistory')
    app.tickHistory = resumeState.tickHistory;
else
    app.tickHistory = createTickHistoryFromExisting(app.rulHistory);
end
app.tickIndex = resumeState.tickIndex;
if isfield(resumeState, 'refreshPeriod') && isfinite(resumeState.refreshPeriod)
    app.refreshPeriod = resumeState.refreshPeriod;
end
if isfield(resumeState, 'serviceEndpoint')
    app = configureServiceEndpoint(app, resumeState.serviceEndpoint);
end
if isfield(resumeState, 'routeDisplayMode')
    savedRouteMode = string(resumeState.routeDisplayMode);
    if savedRouteMode == "Globe" && canUseRouteGlobe(app)
        app.routeDisplayMode = "Globe";
    else
        app.routeDisplayMode = "2D";
    end
end

if ~ismember('FlightClass', app.fleet.Properties.VariableNames)
    app.fleet.FlightClass = flightClasses;
end

if ~ismember('SensorHI', app.fleet.Properties.VariableNames)
    app.fleet.SensorHI = app.fleet.HI;
end

if ~ismember('RUL', app.fleet.Properties.VariableNames)
    app.fleet.RUL = inf(height(app.fleet), 1);
end

if ~ismember('LastMaintenanceCycle', app.fleet.Properties.VariableNames)
    app.fleet.LastMaintenanceCycle = nan(height(app.fleet), 1);
end

if isfield(resumeState, 'selectedEngine') && any(app.fleet.ID == string(resumeState.selectedEngine))
    app.selectedEngine = string(resumeState.selectedEngine);
else
    app.selectedEngine = app.fleet.ID(1);
end
end

function tickHistory = createTickHistoryFromExisting(rulHistory)
tickHistory = containers.Map('KeyType', 'char', 'ValueType', 'any');
keysList = rulHistory.keys;
for i = 1:numel(keysList)
    key = keysList{i};
    tickHistory(key) = 1:numel(rulHistory(key));
end
end

function app = initializeOperationalStates(app)
rng(42);
for i = 1:height(app.fleet)
    hi = app.fleet.HI(i);
    hs = app.fleet.HealthState(i);
    r = rand();

    if isCriticalForMaintenance(app.fleet.RUL(i), hi)
        app.fleet.OpState(i) = "Maintenance";
    elseif hs == "Healthy"
        if r < 0.30
            app.fleet.OpState(i) = "Airborne";
            app.fleet.FlightDuration(i) = randi([2 4]);
        elseif r < 0.45
            app.fleet.OpState(i) = "Just Landed";
        elseif r < 0.65
            app.fleet.OpState(i) = "Departure 0-2h";
        elseif r < 0.80
            app.fleet.OpState(i) = "Departure 2-6h";
        else
            app.fleet.OpState(i) = "Ground Idle";
        end
    else
        if r < 0.25
            app.fleet.OpState(i) = "Airborne";
            app.fleet.FlightDuration(i) = randi([2 4]);
        elseif r < 0.40
            app.fleet.OpState(i) = "Just Landed";
        elseif r < 0.55
            app.fleet.OpState(i) = "Departure 0-2h";
        elseif r < 0.70
            app.fleet.OpState(i) = "Departure 2-6h";
        else
            app.fleet.OpState(i) = "Ground Idle";
        end
    end

    app.fleet.TicksInState(i) = randi([0 2]);
end
end

function app = applyAnalyticsTick(app, tickIndex)
nTotal = size(app.numericData, 1);
batchSize = 9;
startIdx = mod((tickIndex - 1) * batchSize, nTotal) + 1;
endIdx = min(startIdx + batchSize - 1, nTotal);

tickArray = app.numericData(startIdx:endIdx, :);
tickIDs = app.engineIDs(startIdx:endIdx);

[fc, confScores, rulValues, hiValues] = callFleetHealthMicroservice( ...
    app.microserviceUrl, app.microserviceOptions, tickArray, tickIDs);

for i = 1:numel(tickIDs)
    engIdx = find(app.fleet.ID == tickIDs(i), 1);
    if isempty(engIdx), continue; end

    app.fleet.HealthState(engIdx) = fc(i);
    [maxConf, ~] = max(confScores(i, :));
    app.fleet.Confidence(engIdx) = maxConf;
    app.fleet.RUL(engIdx) = rulValues(i);
    app.fleet.HI(engIdx) = hiValues(i);
    app.fleet.SensorHI(engIdx) = hiValues(i);
    app.fleet.TicksSeen(engIdx) = app.fleet.TicksSeen(engIdx) + 1;

    key = char(app.fleet.ID(engIdx));
    app.hiHistory(key) = [app.hiHistory(key), app.fleet.HI(engIdx)];
    app.rulHistory(key) = [app.rulHistory(key), app.fleet.RUL(engIdx)];
    app.cycleHistory(key) = [app.cycleHistory(key), app.fleet.CycleCount(engIdx)];
    app.tickHistory(key) = [app.tickHistory(key), tickIndex];
end
end

function [faultClass, confidenceScores, rulEstimates, healthIndicators] = ...
    callFleetHealthMicroservice(url, options, tickArray, tickIDs)
rows = strings(size(tickArray, 1), 1);
for rowIdx = 1:size(tickArray, 1)
    rows(rowIdx) = "[" + strjoin(string(tickArray(rowIdx, :)), ",") + "]";
end

matrixJson = "[" + strjoin(rows, ",") + "]";
idsJson = jsonencode(struct( ...
    "mwdata", {cellstr(string(tickIDs(:))')}, ...
    "mwsize", [1 numel(tickIDs)], ...
    "mwtype", "string"));
jsonBody = char('{"nargout":4,"rhs":[' + string(matrixJson) + "," + string(idsJson) + "]}");

response = webwrite(url, jsonBody, options);
faultClass = string(response.lhs(1).mwdata(:));
confidenceScores = reshape(response.lhs(2).mwdata, response.lhs(2).mwsize');
rulEstimates = parseRulResponse(response.lhs(3).mwdata);
healthIndicators = double(response.lhs(4).mwdata(:));
end

function endpoints = createServiceEndpointCatalog()
endpoints = struct();
endpoints.Local = struct( ...
    'DisplayName', "Microservice", ...
    'MicroserviceUrl', "http://localhost:9900/FleetHealth_Micro/monitorEngineFleet", ...
    'HealthUrl', "http://localhost:9900/api/health");
endpoints.MPS = struct( ...
    'DisplayName', "MPS", ...
    'MicroserviceUrl', "http://ipws-mps.mathworks.com/FleetHealth_Micro/monitorEngineFleet", ...
    'HealthUrl', "");
end

function app = configureServiceEndpoint(app, endpointName)
endpointName = string(endpointName);
if any(endpointName == ["MPS", "MATLAB Production Server"])
    endpointName = "MPS";
else
    endpointName = "Local";
end

if ~isfield(app, 'serviceEndpoints') || isempty(app.serviceEndpoints)
    app.serviceEndpoints = createServiceEndpointCatalog();
end

endpoint = app.serviceEndpoints.(char(endpointName));
app.serviceEndpoint = endpointName;
app.serviceDisplayName = endpoint.DisplayName;
app.microserviceUrl = char(endpoint.MicroserviceUrl);
app.healthUrl = char(endpoint.HealthUrl);
end

function [isAvailable, message] = checkMicroserviceHealth(app)
isAvailable = false;
try
    if strlength(string(app.healthUrl)) > 0
        webread(app.healthUrl, app.healthOptions);
    else
        if ~isfield(app, 'numericData') || isempty(app.numericData) || ...
                ~isfield(app, 'engineIDs') || isempty(app.engineIDs)
            message = "Endpoint selected; analytics payload not loaded yet";
            return;
        end
        callFleetHealthMicroservice(app.microserviceUrl, app.microserviceOptions, ...
            app.numericData(1, :), app.engineIDs(1));
    end
    isAvailable = true;
    message = sprintf('%s connected', char(app.serviceDisplayName));
catch ME
    message = ME.message;
end
end

function app = updateStreamTimerPeriod(app, periodSeconds)
if ~isfield(app, 'streamTimer') || ~isa(app.streamTimer, 'timer') || ~isvalid(app.streamTimer)
    return;
end

if abs(app.streamTimer.Period - periodSeconds) < 1e-9
    return;
end

wasRunning = strcmp(app.streamTimer.Running, 'on');
if wasRunning
    stop(app.streamTimer);
end
set(app.streamTimer, 'Period', periodSeconds);
if wasRunning
    start(app.streamTimer);
end
end

function app = updateConnectionStatusUI(app)
if ~isfield(app, 'serviceAvailable')
    app.serviceAvailable = true;
end
if ~isfield(app, 'serviceDisplayName')
    app.serviceDisplayName = "Microservice";
end

if app.serviceAvailable
    statusText = sprintf('ONLINE | %s | Mode: %s | Tick %.1fs', ...
        char(app.serviceDisplayName), char(app.dashboardMode), app.refreshPeriod);
    statusColor = [0.3 1 0.5];
else
    statusText = sprintf('OFFLINE | %s | Last known state | Retry %.0fs', ...
        char(app.serviceDisplayName), app.reconnectPeriod);
    statusColor = [1 0.65 0.2];
end

if isfield(app, 'statusLabel') && isvalid(app.statusLabel)
    app.statusLabel.Text = statusText;
    app.statusLabel.FontColor = statusColor;
    tooltipText = "";
    if isfield(app, 'connectionMessage') && strlength(string(app.connectionMessage)) > 0
        tooltipText = string(app.connectionMessage);
    end
    if isfield(app, 'lastConnectionError') && strlength(string(app.lastConnectionError)) > 0
        tooltipText = tooltipText + newline + string(app.lastConnectionError);
    end
    if strlength(tooltipText) > 0
        app.statusLabel.Tooltip = char(tooltipText);
    end
end

if isfield(app, 'tickLabel') && isvalid(app.tickLabel)
    if app.serviceAvailable
        app.tickLabel.Text = sprintf("Tick: %d", app.tickIndex);
    else
        app.tickLabel.Text = sprintf("Tick: %d (last known)", app.tickIndex);
    end
end
end

function rul = parseRulResponse(raw)
if isnumeric(raw)
    rul = double(raw(:));
    return;
end

rul = zeros(numel(raw), 1);
for idx = 1:numel(raw)
    value = raw{idx};
    if (ischar(value) || isstring(value)) && strcmp(string(value), "Inf")
        rul(idx) = Inf;
    else
        rul(idx) = double(value);
    end
end
end

%% ========================================================================
%  DATA LOADING
%  ========================================================================
function app = loadFleetData(app, fig)
addpath(fullfile(fileparts(mfilename('fullpath')), 'dependencies'));

s = load('shuffledFleetData.mat', 'shuffledData', 'mwIDs');
app.shuffledData = s.shuffledData;
app.mwIDs = s.mwIDs;

% Prepare numeric array (Nx362) for microservice calls
featureCols = setdiff(s.shuffledData.Properties.VariableNames, ...
    {'FailureMode','RUL','uniqueID'}, 'stable');
app.numericData = table2array(s.shuffledData(:, featureCols));
app.engineIDs = s.shuffledData.uniqueID;
app.featureCols = featureCols;

% Assign flight class per engine (from first observation of each engine)
nEng = numel(app.mwIDs);
flightClassNames = ["Short","Medium","Long"];
flightClasses = strings(nEng, 1);
for i = 1:nEng
    idx = find(s.shuffledData.uniqueID == app.mwIDs(i), 1);
    fcVal = s.shuffledData.FlightClass(idx);
    flightClasses(i) = flightClassNames(fcVal);
end

resumeState = loadDashboardResumeState(app.snapshotPath);
if ~isempty(resumeState)
    app = applyDashboardResumeState(app, resumeState, flightClasses);
    [app.serviceAvailable, app.connectionMessage] = checkMicroserviceHealth(app);
    if app.serviceAvailable
        uialert(fig, sprintf('Microservice connected - resumed from tick %d.', app.tickIndex), ...
            'Microservice Connected', 'Icon', 'success', 'CloseFcn', @(~,~)[]);
    else
        app.connectionMessage = "Connection failure - displaying last known fleet status from snapshot";
        uialert(fig, sprintf('%s. Rechecking %s every %.0f seconds.', ...
            app.connectionMessage, app.healthUrl, app.reconnectPeriod), ...
            'Microservice Unreachable', 'Icon', 'warning', 'CloseFcn', @(~,~)[]);
    end
    return;
end

% Build warm state from the current monitorEngineFleet contract. Do not use
% dashboardWarmup.mat here; it may contain legacy 0..100 HI values.
app = initializeFleetPlaybackState(app, flightClasses);

warmupTicks = 1;
[app.serviceAvailable, app.connectionMessage] = checkMicroserviceHealth(app);
if app.serviceAvailable
    clear('monitorEngineFleet');
    try
        for warmTick = 1:warmupTicks
            app = applyAnalyticsTick(app, warmTick);
        end
        app.tickIndex = warmupTicks;
    catch ME
        app.serviceAvailable = false;
        app.connectionMessage = "Connection failure during warmup - displaying initialized fleet status";
        app.lastConnectionError = ME.message;
    end
end

% Status message
if app.serviceAvailable
    uialert(fig, sprintf('Microservice connected - %d engines, warmup %d ticks computed.', nEng, warmupTicks), ...
        'Microservice Connected', 'Icon', 'success', 'CloseFcn', @(~,~)[]);
else
    if strlength(string(app.connectionMessage)) == 0
        app.connectionMessage = "Connection failure - displaying initialized fleet status";
    end
    uialert(fig, sprintf('%s. Rechecking %s every %.0f seconds.', ...
        app.connectionMessage, app.healthUrl, app.reconnectPeriod), ...
        'Microservice Unreachable', 'Icon', 'warning', 'CloseFcn', @(~,~)[]);
end
end

function app = initializeFleetPlaybackState(app, flightClasses)
nEng = numel(app.mwIDs);
app.fleet = table(app.mwIDs, ...
    repmat("Healthy", nEng, 1), ...
    ones(nEng, 1), ...
    inf(nEng, 1), ...
    ones(nEng, 1), ...
    repmat("Ground Idle", nEng, 1), ...
    zeros(nEng, 1), ...
    flightClasses, ...
    zeros(nEng, 1), ...
    zeros(nEng, 1), ...
    ones(nEng, 1), ...
    zeros(nEng, 1), ...
    nan(nEng, 1), ...
    'VariableNames', {'ID','HealthState','Confidence','RUL','HI','OpState','TicksSeen','FlightClass','TicksInState','FlightDuration','SensorHI','CycleCount','LastMaintenanceCycle'});

app.hiHistory = containers.Map('KeyType', 'char', 'ValueType', 'any');
app.rulHistory = containers.Map('KeyType', 'char', 'ValueType', 'any');
app.cycleHistory = containers.Map('KeyType', 'char', 'ValueType', 'any');
app.tickHistory = containers.Map('KeyType', 'char', 'ValueType', 'any');
for i = 1:nEng
    key = char(app.mwIDs(i));
    app.hiHistory(key) = [];
    app.rulHistory(key) = [];
    app.cycleHistory(key) = [];
    app.tickHistory(key) = [];
end

app = initializeOperationalStates(app);
app.selectedEngine = app.mwIDs(1);
app.tickIndex = 0;
end

function app = resetEngineAfterMaintenance(app, engIdx)
app.fleet.HealthState(engIdx) = "Healthy";
app.fleet.Confidence(engIdx) = 1;
app.fleet.RUL(engIdx) = Inf;
app.fleet.HI(engIdx) = 1;
app.fleet.SensorHI(engIdx) = 1;
app.fleet.LastMaintenanceCycle(engIdx) = app.fleet.CycleCount(engIdx);

key = char(app.fleet.ID(engIdx));
app.hiHistory(key) = [app.hiHistory(key), app.fleet.HI(engIdx)];
app.rulHistory(key) = [app.rulHistory(key), app.fleet.RUL(engIdx)];
app.cycleHistory(key) = [app.cycleHistory(key), app.fleet.CycleCount(engIdx)];
app.tickHistory(key) = [app.tickHistory(key), app.tickIndex];
end

%% ========================================================================
%  STREAMING ENGINE
%  ========================================================================
function streamTick(fig)
if ~isvalid(fig), return; end
app = fig.UserData;

if ~isfield(app, 'serviceAvailable')
    app.serviceAvailable = true;
end

if ~app.serviceAvailable
    [isAvailable, message] = checkMicroserviceHealth(app);
    if ~isAvailable
        app.connectionMessage = "Connection failure - displaying last known fleet status";
        app.lastConnectionError = message;
        app = updateConnectionStatusUI(app);
        fig.UserData = app;
        drawnow;
        return;
    end

    app.serviceAvailable = true;
    app.connectionMessage = "Microservice connected - live stream resumed";
    app = updateStreamTimerPeriod(app, app.refreshPeriod);
    app = updateConnectionStatusUI(app);
end

nextTick = app.tickIndex + 1;
try
    app = applyAnalyticsTick(app, nextTick);
    app.tickIndex = nextTick;
    app.serviceAvailable = true;
    app.connectionMessage = "Microservice connected";
catch ME
    app.serviceAvailable = false;
    app.connectionMessage = "Connection failure - displaying last known fleet status";
    app.lastConnectionError = ME.message;
    app = updateStreamTimerPeriod(app, app.reconnectPeriod);
    app = updateConnectionStatusUI(app);
    fig.UserData = app;
    drawnow;
    return;
end

% Advance state machine for ALL 99 engines (deterministic transitions)
changedClusters = false(6,1);
for engIdx = 1:height(app.fleet)
    oldState = app.fleet.OpState(engIdx);
    app.fleet.TicksInState(engIdx) = app.fleet.TicksInState(engIdx) + 1;
    tis = app.fleet.TicksInState(engIdx);
    newState = oldState;

    switch oldState
        case "Airborne"
            % Flight lasts FlightDuration ticks, then land
            if tis >= app.fleet.FlightDuration(engIdx)
                newState = "Just Landed";
                app.fleet.CycleCount(engIdx) = app.fleet.CycleCount(engIdx) + 1;
            end

        case "Just Landed"
            % Spend 1 tick in Just Landed, then move to ground ops
            if tis >= 1
                if shouldEnterMaintenance(app, engIdx)
                    newState = "Maintenance";
                elseif rand() < 0.6
                    newState = "Departure 0-2h";
                else
                    newState = "Departure 2-6h";
                end
            end

        case "Departure 0-2h"
            % Next to fly: 2-4 ticks then airborne
            if tis >= randi([2 4])
                newState = "Airborne";
                app.fleet.FlightDuration(engIdx) = randi([2 4]);
            end

        case "Departure 2-6h"
            % Wait 3-6 ticks, then move to 0-2h or ground idle
            if tis >= randi([3 6])
                if rand() < 0.7
                    newState = "Departure 0-2h";
                else
                    newState = "Ground Idle";
                end
            end

        case "Ground Idle"
            % Can go to Departure 2-6h or Maintenance (if RUL critical)
            if shouldEnterMaintenance(app, engIdx)
                newState = "Maintenance";
            elseif tis >= randi([3 8])
                newState = "Departure 2-6h";
            end

        case "Maintenance"
            % Three maintenance cycles means three full 99-engine analytics sweeps.
            if tis >= maintenanceDurationTicks(app)
                newState = "Ground Idle";
            end
    end

    if newState ~= oldState
        app.fleet.OpState(engIdx) = newState;
        app.fleet.TicksInState(engIdx) = 0;
        if newState == "Maintenance"
            app.fleet.LastMaintenanceCycle(engIdx) = app.fleet.CycleCount(engIdx);
        elseif oldState == "Maintenance"
            app = resetEngineAfterMaintenance(app, engIdx);
        end
        for s = 1:6
            if oldState == app.stateNames(s) || newState == app.stateNames(s)
                changedClusters(s) = true;
            end
        end
    end

end

% Update timestamp
app.timestampLabel.Text = sprintf("Tick %d | %s", app.tickIndex, ...
    string(datetime('now','Format','HH:mm:ss')));
app = updateConnectionStatusUI(app);

fig.UserData = app;

% Process pending UI events (allows dropdown/click callbacks to fire)
drawnow;

% Re-render clusters that had membership changes
if any(changedClusters)
    renderClustersSelective(fig, changedClusters);
end
% In-place color/HI updates for cards in unchanged clusters
updateCardsInPlace(fig, app.fleet.ID, changedClusters);
updateClusterTitles(fig);
updateKPIs(fig);
updateSelectedEngine(fig);
app = fig.UserData;
app.routeMapNeedsRender = true;
fig.UserData = app;
if isRouteMapVisible(app)
    scheduleRouteMapRender(fig);
end
persistDashboardSnapshot(app);
end


%% ========================================================================
%  UI BUILDING FUNCTIONS
%  ========================================================================
function app = buildKPIPanel(app, parentGrid)
kpiPanel = uipanel(parentGrid, 'Title', 'FLEET STATUS', ...
    'BackgroundColor', [0.12 0.12 0.14], ...
    'ForegroundColor', [0.5 0.8 1], ...
    'FontWeight', 'bold', 'FontSize', 16);
kpiPanel.Layout.Row = 1;

g = uigridlayout(kpiPanel, [2 3]);
g.RowHeight = {'1x', '1x'};
g.ColumnWidth = {'1x', '1x', '1x'};
g.Padding = [8 8 8 8];
g.RowSpacing = 6;
g.ColumnSpacing = 6;
g.BackgroundColor = [0.12 0.12 0.14];

app.kpiTotal = createKPITile(g, 1, 1, "TOTAL", "99", [0.2 0.2 0.25], [0.9 0.9 1]);
app.kpiHealthy = createKPITile(g, 1, 2, "HEALTHY", "0", [0.1 0.25 0.1], [0.3 1 0.4]);
app.kpiFaulted = createKPITile(g, 1, 3, "DEGRADING", "0", [0.3 0.25 0.1], [1 0.7 0.2]);
app.kpiCritical = createKPITile(g, 2, 1, "CRITICAL", "0", [0.3 0.1 0.1], [1 0.3 0.3]);
app.kpiAirborne = createKPITile(g, 2, 2, "EARLY FAILURE", "0", [0.1 0.15 0.3], [0.4 0.7 1]);
app.kpiMaint = createKPITile(g, 2, 3, "MAINT", "0", [0.2 0.2 0.15], [0.8 0.8 0.5]);
end

function tile = createKPITile(grid, row, col, titleStr, valueStr, bgColor, fgColor)
p = uipanel(grid, 'BorderType', 'line', ...
    'BackgroundColor', bgColor, ...
    'HighlightColor', fgColor * 0.6);
p.Layout.Row = row;
p.Layout.Column = col;

tg = uigridlayout(p, [2 1]);
tg.RowHeight = {'1x', '2x'};
tg.Padding = [4 2 4 2];
tg.RowSpacing = 0;
tg.BackgroundColor = bgColor;

uilabel(tg, 'Text', titleStr, 'FontSize', 14, ...
    'FontColor', fgColor * 0.8, 'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center');

tile = uilabel(tg, 'Text', valueStr, 'FontSize', 32, ...
    'FontWeight', 'bold', 'FontColor', fgColor, ...
    'HorizontalAlignment', 'center');
end

function app = buildControlPanel(app, parentGrid)
ctrlPanel = uipanel(parentGrid, 'Title', 'STREAM CONTROL', ...
    'BackgroundColor', [0.12 0.12 0.14], ...
    'ForegroundColor', [0.5 0.8 1], ...
    'FontWeight', 'bold', 'FontSize', 16);
ctrlPanel.Layout.Row = 2;

g = uigridlayout(ctrlPanel, [5 2]);
g.RowHeight = {'1x', '1x', '1x', '1x', '1x'};
g.ColumnWidth = {'1x', '1x'};
g.Padding = [10 6 10 6];
g.RowSpacing = 4;
g.ColumnSpacing = 8;
g.BackgroundColor = [0.12 0.12 0.14];

uilabel(g, 'Text', 'Refresh Rate (sec):', 'FontSize', 11, ...
    'FontColor', [0.7 0.8 0.9]);
app.refreshSpinner = uispinner(g, 'Value', app.refreshPeriod, 'Limits', [0.5 30], ...
    'Step', 0.5, 'FontSize', 11, ...
    'ValueChangedFcn', @(src,~) updateRefreshRate(src));

app.statusLabel = uilabel(g, 'Text', 'Database Connected', ...
    'FontSize', 11, 'FontWeight', 'bold', 'FontColor', [0.3 1 0.5]);

app.tickLabel = uilabel(g, 'Text', 'Tick: 0', 'FontSize', 11, 'FontColor', [0.6 0.7 0.8]);
app = updateConnectionStatusUI(app);

uilabel(g, 'Text', 'Service:', 'FontSize', 11, 'FontColor', [0.7 0.8 0.9]);
app.serviceSwitch = uiswitch(g, 'slider', 'Items', {'Microservice', 'MPS'}, ...
    'ItemsData', {'Local', 'MPS'}, 'Value', char(app.serviceEndpoint), ...
    'FontSize', 11, 'FontColor', [0.6 0.7 0.8],...
    'ValueChangedFcn', @(src,~) updateServiceEndpoint(src));

uilabel(g, 'Text', 'Map View:', 'FontSize', 11, 'FontColor', [0.7 0.8 0.9]);
app.mapViewDropdown = uidropdown(g, ...
    'Items', {'2D Routes', '3D Globe'}, ...
    'ItemsData', {'2D', 'Globe'}, ...
    'Value', char(app.routeDisplayMode), ...
    'FontSize', 11, ...
    'ValueChangedFcn', @(src,~) updateRouteDisplayMode(src));
app = updateRouteViewControlState(app);

app.resetButton = uibutton(g, 'push', ...
    'Text', 'Reset Ticker', ...
    'FontSize', 11, ...
    'FontWeight', 'bold', ...
    'FontColor', [0.05 0.08 0.10], ...
    'BackgroundColor', [0.95 0.72 0.25], ...
    'ButtonPushedFcn', @(src,~) resetPlaybackFromControl(src));
app.resetButton.Layout.Row = 5;
app.resetButton.Layout.Column = [1 2];
end

function app = buildFlightClassPanel(app, parentGrid)
fcPanel = uipanel(parentGrid, 'Title', 'DISTRIBUTION', ...
    'BackgroundColor', [0.12 0.12 0.14], ...
    'ForegroundColor', [0.5 0.8 1], ...
    'FontWeight', 'bold', 'FontSize', 16);
fcPanel.Layout.Row = 3;

g = uigridlayout(fcPanel, [2 1]);
g.RowHeight = {'1x', '1.5x'};
g.Padding = [8 8 8 8];
g.RowSpacing = 6;
g.BackgroundColor = [0.12 0.12 0.14];

% Flight class section
app.flightClassList = uitextarea(g, 'Value', {'Flight Classes: loading...'}, ...
    'FontName', 'Consolas', 'FontSize', 14, ...
    'FontColor', [0.6 0.9 0.7], ...
    'BackgroundColor', [0.08 0.08 0.10], ...
    'Editable', false);

% Fault mode section
app.faultDistList = uitextarea(g, 'Value', {'Fault Modes: loading...'}, ...
    'FontName', 'Consolas', 'FontSize', 14, ...
    'FontColor', [0.7 0.85 1], ...
    'BackgroundColor', [0.08 0.08 0.10], ...
    'Editable', false);
end

function app = buildRiskSummaryPanel(app, parentGrid)
rsPanel = uipanel(parentGrid, 'Title', 'TOP RISK ENGINES', ...
    'BackgroundColor', [0.12 0.12 0.14], ...
    'ForegroundColor', [1 0.4 0.4], ...
    'FontWeight', 'bold', 'FontSize', 16);
rsPanel.Layout.Row = 4;

g = uigridlayout(rsPanel, [1 1]);
g.Padding = [8 8 8 8];
g.BackgroundColor = [0.12 0.12 0.14];

app.riskList = uitextarea(g, 'Value', {'Loading...'}, ...
    'FontName', 'Consolas', 'FontSize', 14, ...
    'FontColor', [1 0.6 0.4], ...
    'BackgroundColor', [0.08 0.06 0.06], ...
    'Editable', false);
end

function app = buildTitleRibbon(app, parentGrid)
ribbon = uipanel(parentGrid, 'BorderType', 'line', ...
    'BackgroundColor', [0.04 0.08 0.16], ...
    'HighlightColor', [0.1 0.5 0.9]);
ribbon.Layout.Row = 1;

rg = uigridlayout(ribbon, [2 3]);
rg.RowHeight = {'1x', 14};
rg.ColumnWidth = {'1x', '2x', '1x'};
rg.Padding = [10 4 10 2];
rg.RowSpacing = 0;
rg.BackgroundColor = [0.04 0.08 0.16];

uilabel(rg, 'Text', 'FLEET OPERATIONS — LIVE', ...
    'FontSize', 11, 'FontColor', [0.5 0.7 0.9], ...
    'HorizontalAlignment', 'left');

uilabel(rg, 'Text', 'T U R B O P U L S E', ...
    'FontSize', 36, 'FontWeight', 'bold', ...
    'FontColor', [0.3 0.8 1], ...
    'HorizontalAlignment', 'center');

app.timestampLabel = uilabel(rg, 'Text', string(datetime('now','Format','dd-MMM-yyyy HH:mm')), ...
    'FontSize', 11, 'FontColor', [0.5 0.7 0.9], ...
    'HorizontalAlignment', 'right');

% Subtitle row
uilabel(rg, 'Text', '', 'FontSize', 1);
uilabel(rg, 'Text', 'Aircraft Engine Fleet Health Monitoring — Trustworthy AI Predictions', ...
    'FontSize', 12, 'FontColor', [0.4 0.6 0.75], ...
    'HorizontalAlignment', 'center');
uilabel(rg, 'Text', '', 'FontSize', 1);
end

function app = buildClusterView(app, parentGrid)
clusterPanel = uipanel(parentGrid, 'BorderType', 'none', 'BackgroundColor', [0.10 0.10 0.12]);
clusterPanel.Layout.Row = 1;

g = uigridlayout(clusterPanel, [2 3]);
g.RowHeight = {'1x', '1x'};
g.ColumnWidth = {'1x', '1x', '1x'};
g.Padding = [6 6 6 6];
g.RowSpacing = 6;
g.ColumnSpacing = 6;
g.BackgroundColor = [0.10 0.10 0.12];

app.clusterPanels = gobjects(6, 1);
app.clusterTitles = gobjects(6, 1);
app.clusterIcons = gobjects(6, 1);
clusterIconFiles = ["icon_Airborne.png", "icon_JustLanded.png", ...
    "icon_Departurein2hrs.png", "icon_Departurein6hrs.png", ...
    "icon_GroundIdle.png", "icon_Maintenance.png"];
positions = {[1,1],[1,2],[1,3],[2,1],[2,2],[2,3]};

for i = 1:6
    p = uipanel(g, 'BorderType', 'line', 'BackgroundColor', [0.11 0.11 0.13], 'HighlightColor', [0.25 0.4 0.6], 'Scrollable', 'on');
    p.Layout.Row = positions{i}(1);
    p.Layout.Column = positions{i}(2);
    pg = uigridlayout(p, [2 1]);
    pg.RowHeight = {34, '1x'};
    pg.Padding = [4 4 4 2];
    pg.RowSpacing = 3;
    pg.BackgroundColor = [0.11 0.11 0.13];

    headerGrid = uigridlayout(pg, [1 2]);
    headerGrid.ColumnWidth = {28, '1x'};
    headerGrid.Padding = [0 0 0 0];
    headerGrid.ColumnSpacing = 6;
    headerGrid.BackgroundColor = [0.11 0.11 0.13];

    iconPath = fullfile(app.basePath, clusterIconFiles(i));
    app.clusterIcons(i) = uiimage(headerGrid, 'ImageSource', iconPath, 'ScaleMethod', 'fit');
    app.clusterIcons(i).Layout.Row = 1;
    app.clusterIcons(i).Layout.Column = 1;

    app.clusterTitles(i) = uilabel(headerGrid, 'Text', app.stateNames(i), ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'FontColor', [0.7 0.88 1]);
    app.clusterTitles(i).Layout.Row = 1;
    app.clusterTitles(i).Layout.Column = 2;

    innerPanel = uipanel(pg, 'BorderType', 'none', 'BackgroundColor', [0.09 0.09 0.11], 'Scrollable', 'on');
    app.clusterPanels(i) = innerPanel;
end
end

function app = buildRouteMap(app, parentGrid)
app.routeMapParent = parentGrid;
delete(parentGrid.Children);

if app.routeDisplayMode == "Globe" && canUseRouteGlobe(app)
    globePanel = uipanel(parentGrid, 'BorderType', 'none', ...
        'BackgroundColor', [0.02 0.025 0.035]);
    globePanel.Layout.Row = 1;
    globePanel.Layout.Column = 1;
    routeAxes = geoglobe(globePanel);
    app.routeMapKind = "Globe";
    configureGlobeRouteAxes(routeAxes);
elseif app.isOfflineMode
    routeAxes = uiaxes(parentGrid);
    routeAxes.Layout.Row = 1;
    routeAxes.Layout.Column = 1;
    app.routeMapKind = "Offline2D";
    configureOfflineRouteAxes(routeAxes);
else
    routeAxes = geoaxes(parentGrid);
    routeAxes.Layout.Row = 1;
    routeAxes.Layout.Column = 1;
    app.routeMapKind = "Online2D";
    configureOnlineRouteAxes(routeAxes);
end

app.routeAxes = routeAxes;
app.routeCityLabels = gobjects(0);
app.routeMapObjects = containers.Map('KeyType', 'char', 'ValueType', 'any');
end

function configureOnlineRouteAxes(routeAxes)
routeAxes.Color = [0.02 0.025 0.035];
routeAxes.GridColor = [0.22 0.24 0.28];
routeAxes.LatitudeLabel.String = '';
routeAxes.LongitudeLabel.String = '';
routeAxes.Toolbar.Visible = 'off';
applyTightRouteAxesLayout(routeAxes);
geobasemap(routeAxes, 'satellite');
[latLimits, lonLimits] = indiaRouteMapLimits();
geolimits(routeAxes, latLimits, lonLimits);
applyTightRouteAxesLayout(routeAxes);
end

function applyTightRouteAxesLayout(routeAxes)
try
    routeAxes.LatitudeAxis.Visible = 'off';
    routeAxes.LongitudeAxis.Visible = 'off';
    routeAxes.LatitudeAxis.TickValues = [];
    routeAxes.LongitudeAxis.TickValues = [];
    routeAxes.LatitudeAxis.TickLabels = {};
    routeAxes.LongitudeAxis.TickLabels = {};
    routeAxes.LatitudeAxis.TickLength = [0 0];
    routeAxes.LongitudeAxis.TickLength = [0 0];
    routeAxes.LatitudeAxis.Color = routeAxes.Color;
    routeAxes.LongitudeAxis.Color = routeAxes.Color;
    routeAxes.LatitudeAxis.TickLabelColor = routeAxes.Color;
    routeAxes.LongitudeAxis.TickLabelColor = routeAxes.Color;
catch
end
try
    routeAxes.TickLength = [0 0];
catch
end
try
    routeAxes.Grid = 'off';
catch
end
try
    routeAxes.Box = 'off';
catch
end
try
    routeAxes.Scalebar.Visible = 'off';
catch
    try
        routeAxes.Scalebar = 'off';
    catch
    end
end
try
    routeAxes.PositionConstraint = 'outerposition';
catch
end
try
    routeAxes.Units = 'normalized';
    routeAxes.Position = [0 0 1 1];
    routeAxes.InnerPosition = [0 0 1 1];
    routeAxes.OuterPosition = [0 0 1 1];
catch
end
try
    routeAxes.LooseInset = [0 0 0 0];
catch
end
end

function configureOfflineRouteAxes(routeAxes)
routeAxes.Color = [0.02 0.025 0.035];
routeAxes.XColor = [0.35 0.40 0.46];
routeAxes.YColor = [0.35 0.40 0.46];
routeAxes.GridColor = [0.22 0.24 0.28];
routeAxes.Toolbar.Visible = 'off';
routeAxes.Box = 'on';
routeAxes.XGrid = 'on';
routeAxes.YGrid = 'on';
routeAxes.XLabel.String = 'Longitude';
routeAxes.YLabel.String = 'Latitude';
[latLimits, lonLimits] = indiaRouteMapLimits();
xlim(routeAxes, lonLimits);
ylim(routeAxes, latLimits);
axis(routeAxes, 'manual');
end

function configureGlobeRouteAxes(routeAxes)
routeAxes.Basemap = 'satellite';
try
    routeAxes.Units = 'normalized';
    routeAxes.Position = [0 0 1 1];
catch
end
try
    campos(routeAxes, 21.0, 82.0, 7200000);
    campitch(routeAxes, -82);
    camheading(routeAxes, 0);
catch
end
end

function app = renderAirborneRouteMap(app)
if ~isfield(app, 'routeAxes') || ~isvalid(app.routeAxes)
    return;
end

routeAxes = app.routeAxes;
if ~isfield(app, 'routeMapObjects') || ~isa(app.routeMapObjects, 'containers.Map')
    app.routeMapObjects = containers.Map('KeyType', 'char', 'ValueType', 'any');
end

[shortRoutes, mediumRoutes, longRoutes] = getRouteCatalogs2D();
airborne = app.fleet(app.fleet.OpState == "Airborne", :);
airborneIDs = string(airborne.ID);

existingKeys = string(app.routeMapObjects.keys);
staleKeys = setdiff(existingKeys, airborneIDs);
for i = 1:numel(staleKeys)
    key = char(staleKeys(i));
    deleteFlightGraphics(app.routeMapObjects(key));
    remove(app.routeMapObjects, key);
end

if isRouteGlobe(routeAxes)
    keysList = app.routeMapObjects.keys;
    for i = 1:numel(keysList)
        deleteFlightGraphics(app.routeMapObjects(keysList{i}));
    end
    app.routeMapObjects = containers.Map('KeyType', 'char', 'ValueType', 'any');
end

classCounters = containers.Map({'Short','Medium','Long'}, {0, 0, 0});
hold(routeAxes, 'on');
for i = 1:height(airborne)
    key = char(airborne.ID(i));
    flightClass = char(airborne.FlightClass(i));
    classCounters(flightClass) = classCounters(flightClass) + 1;
    healthBucket = getFleetHealthBucket(airborne.HealthState(i), airborne.RUL(i), airborne.HI(i), airborne.OpState(i));
    healthColor = routeHealthColor(healthBucket);

    if app.routeMapObjects.isKey(key)
        flightGraphics = app.routeMapObjects(key);
        route = flightGraphics.Route;
        if ~isfield(flightGraphics, 'HealthBucket') || string(flightGraphics.HealthBucket) ~= healthBucket
            flightGraphics = updateFlightGraphicColor(flightGraphics, healthBucket, healthColor);
        end
        flightGraphics = updateFlightGraphicMetadata(flightGraphics, route, airborne.ID(i), ...
            healthBucket, airborne.HealthState(i), airborne.RUL(i), airborne.HI(i));
    else
        route = selectRouteForEngine2D(airborne.ID(i), airborne.FlightClass(i), ...
            airborne.CycleCount(i), classCounters(flightClass), ...
            shortRoutes, mediumRoutes, longRoutes);
        progress = mod(0.17 * i + 0.03 * airborne.CycleCount(i), 0.82) + 0.08;
        flightGraphics = plotAirborneRoute(routeAxes, route, airborne.ID(i), progress, healthBucket, healthColor, ...
            airborne.HealthState(i), airborne.RUL(i), airborne.HI(i));
    end

    app.routeMapObjects(key) = flightGraphics;
end
app = updateRouteCityLabels(app);
app = updateRouteMapLimits(app);
if isRouteGlobe(routeAxes)
    drawnow limitrate;
end
hold(routeAxes, 'off');
app.routeMapNeedsRender = false;
end

function deleteFlightGraphics(flightGraphics)
if ~isstruct(flightGraphics) || ~isfield(flightGraphics, 'Handles')
    return;
end

for i = 1:numel(flightGraphics.Handles)
    if isvalid(flightGraphics.Handles(i))
        delete(flightGraphics.Handles(i));
    end
end
end

function centerTabChanged(fig)
if ~isvalid(fig)
    return;
end

app = fig.UserData;
if isRouteMapVisible(app) && (~isfield(app, 'routeMapNeedsRender') || app.routeMapNeedsRender)
    scheduleRouteMapRender(fig);
end
end

function scheduleRouteMapRender(fig)
if ~isvalid(fig)
    return;
end

app = fig.UserData;
if isfield(app, 'routeRenderTimer') && isa(app.routeRenderTimer, 'timer') && isvalid(app.routeRenderTimer)
    cancelRouteRenderTimer(app.routeRenderTimer);
end

app.routeRenderTimer = timer('ExecutionMode', 'singleShot', ...
    'StartDelay', 0.1, ...
    'TimerFcn', @(src,~) routeMapRenderTimer(fig, src), ...
    'StopFcn', @(src,~) deleteStoppedTimer(src));
fig.UserData = app;
start(app.routeRenderTimer);
end

function routeMapRenderTimer(fig, renderTimer)
if ~isvalid(fig)
    return;
end

app = fig.UserData;
try
    if isRouteMapVisible(app)
        app = renderAirborneRouteMap(app);
    end
catch ME
    warning('EngineFleetDashboard:RouteMapRenderFailed', ...
        'Route map render failed: %s', ME.message);
end

if isvalid(fig)
    if nargin > 1 && isa(renderTimer, 'timer') && isvalid(renderTimer) && ...
            isfield(app, 'routeRenderTimer') && isequal(app.routeRenderTimer, renderTimer)
        app.routeRenderTimer = [];
    end
fig.UserData = app;
end
end

function deleteStoppedTimer(timerObj)
if isa(timerObj, 'timer') && isvalid(timerObj) && strcmp(timerObj.Running, 'off')
    delete(timerObj);
end
end

function cancelRouteRenderTimer(timerObj)
if ~isa(timerObj, 'timer') || ~isvalid(timerObj)
    return;
end

if strcmp(timerObj.Running, 'on')
    stop(timerObj);
else
    deleteStoppedTimer(timerObj);
end
end

function tf = isRouteMapVisible(app)
tf = isfield(app, 'centerTabs') && isvalid(app.centerTabs) && ...
    isfield(app, 'routeMapTab') && isvalid(app.routeMapTab) && ...
    app.centerTabs.SelectedTab == app.routeMapTab;
end

function [shortRoutes, mediumRoutes, longRoutes] = getRouteCatalogs2D()
india = table( ...
    ["Delhi";"Mumbai";"Bengaluru";"Chennai";"Hyderabad";"Kolkata";"Ahmedabad";"Pune";"Jaipur";"Lucknow";"Kochi";"Guwahati";"Indore";"Bhubaneswar";"Nagpur";"Coimbatore";"Visakhapatnam";"Goa";"Srinagar";"Raipur";"Ranchi";"Mangaluru";"Varanasi";"Jodhpur";"Leh"], ...
    [28.6139;19.0760;12.9716;13.0827;17.3850;22.5726;23.0225;18.5204;26.9124;26.8467;9.9312;26.1445;22.7196;20.2961;21.1458;11.0168;17.6868;15.2993;34.0837;21.2514;23.3441;12.9141;25.3176;26.2389;34.1526], ...
    [77.2090;72.8777;77.5946;80.2707;78.4867;88.3639;72.5714;73.8567;75.7873;80.9462;76.2673;91.7362;75.8577;85.8245;79.0882;76.9558;83.2185;74.1240;74.7973;81.6296;85.3096;74.8560;82.9739;73.0243;77.5771], ...
    'VariableNames', {'City','Lat','Lon'});

near = table( ...
    ["Kathmandu";"Dhaka";"Dubai";"Muscat";"Doha";"Colombo";"Male";"Bangkok";"Singapore";"Kuala Lumpur";"Abu Dhabi";"Bahrain";"Kuwait City"], ...
    [27.7172;23.8103;25.2048;23.5880;25.2854;6.9271;4.1755;13.7563;1.3521;3.1390;24.4539;26.0667;29.3759], ...
    [85.3240;90.4125;55.2708;58.3829;51.5310;79.8612;73.5093;100.5018;103.8198;101.6869;54.3773;50.5577;47.9774], ...
    'VariableNames', {'City','Lat','Lon'});

far = table( ...
    ["London";"Paris";"Amsterdam";"Frankfurt";"Zurich";"Rome";"Madrid";"Munich";"Milan";"Copenhagen";"Vienna";"Moscow";"St Petersburg";"Beijing";"Shanghai";"Guangzhou";"Taipei";"Hong Kong";"Seoul";"Tokyo";"Osaka";"Sydney";"Melbourne";"Perth";"Auckland";"Christchurch"], ...
    [51.5074;48.8566;52.3676;50.1109;47.3769;41.9028;40.4168;48.1351;45.4642;55.6761;48.2082;55.7558;59.9311;39.9042;31.2304;23.1291;25.0330;22.3193;37.5665;35.6762;34.6937;-33.8688;-37.8136;-31.9505;-36.8509;-43.5321], ...
    [-0.1278;2.3522;4.9041;8.6821;8.5417;12.4964;-3.7038;11.5820;9.1900;12.5683;16.3738;37.6173;30.3609;116.4074;121.4737;113.2644;121.5654;114.1694;126.9780;139.6503;135.5023;151.2093;144.9631;115.8605;174.7645;172.6362], ...
    'VariableNames', {'City','Lat','Lon'});

shortRoutes = buildRouteSet2D("Short", india, india, 25, 7, [2.0 2.8]);
mediumRoutes = buildRouteSet2D("Medium", india(1:12, :), near, 33, 5, [3.0 5.0]);
longRoutes = buildRouteSet2D("Long", india(1:12, :), far, 39, 9, [7.0 10.0]);
end

function routes = buildRouteSet2D(className, origins, destinations, nRoutes, offset, durationRange)
origin = strings(nRoutes, 1);
originLat = zeros(nRoutes, 1);
originLon = zeros(nRoutes, 1);
destination = strings(nRoutes, 1);
destLat = zeros(nRoutes, 1);
destLon = zeros(nRoutes, 1);
durationHours = zeros(nRoutes, 1);
for i = 1:nRoutes
    oi = mod(i - 1, height(origins)) + 1;
    di = mod((i - 1) * offset + i, height(destinations)) + 1;
    if origins.City(oi) == destinations.City(di)
        di = mod(di, height(destinations)) + 1;
    end
    origin(i) = origins.City(oi);
    originLat(i) = origins.Lat(oi);
    originLon(i) = origins.Lon(oi);
    destination(i) = destinations.City(di);
    destLat(i) = destinations.Lat(di);
    destLon(i) = destinations.Lon(di);
    durationHours(i) = durationRange(1) + (durationRange(2) - durationRange(1)) * mod(i - 1, 9) / 8;
end
routes = table(repmat(className, nRoutes, 1), origin, originLat, originLon, ...
    destination, destLat, destLon, durationHours, ...
    'VariableNames', {'Class','Origin','OriginLat','OriginLon', ...
    'Destination','DestLat','DestLon','DurationHours'});
end

function route = selectRouteForEngine2D(engineID, flightClass, cycleCount, classCounter, shortRoutes, mediumRoutes, longRoutes)
switch string(flightClass)
    case "Short"
        routes = shortRoutes;
    case "Medium"
        routes = mediumRoutes;
    otherwise
        routes = longRoutes;
end
seed = sum(double(char(string(engineID)))) + round(double(cycleCount)) + classCounter * 11;
route = routes(mod(seed - 1, height(routes)) + 1, :);

if route.Class == "Short"
    route.Direction = "Domestic";
elseif mod(seed, 2) == 0
    [route.Origin, route.Destination] = deal(route.Destination, route.Origin);
    [route.OriginLat, route.DestLat] = deal(route.DestLat, route.OriginLat);
    [route.OriginLon, route.DestLon] = deal(route.DestLon, route.OriginLon);
    route.Direction = "Inbound";
else
    route.Direction = "Outbound";
end
end

function flightGraphics = plotAirborneRoute(routeAxes, route, engineID, progress, healthBucket, healthColor, healthState, rul, hi)
[lat, lon] = routeCurve2D(route);
isGlobeAxes = isRouteGlobe(routeAxes);
isGeoAxes = ~isGlobeAxes && isprop(routeAxes, 'Basemap');
if isGlobeAxes
    alt = routeAltitudeProfile(lat, route);
    surfaceAlt = zeros(size(lat)) + 25000;
    surfaceLine = geoplot3(routeAxes, lat, lon, surfaceAlt, '-', ...
        'Color', min(healthColor + 0.08, 1), 'LineWidth', 1.5);
    surfaceLine = configureGlobeLine(surfaceLine);
    routeLine = geoplot3(routeAxes, lat, lon, alt, '-', ...
        'Color', min(healthColor + 0.04, 1), 'LineWidth', 1.0);
    routeLine = configureGlobeLine(routeLine);
elseif isGeoAxes
    surfaceLine = gobjects(1);
    routeLine = geoplot(routeAxes, lat, lon, '-', ...
        'Color', healthColor, 'LineWidth', 1.15, ...
        'DisplayName', sprintf('%s: %s > %s', engineID, route.Origin, route.Destination));
else
    surfaceLine = gobjects(1);
    routeLine = plot(routeAxes, lon, lat, '-', ...
        'Color', healthColor, 'LineWidth', 1.15, ...
        'DisplayName', sprintf('%s: %s > %s', engineID, route.Origin, route.Destination));
end
configureFlightMetadata(routeLine, route, engineID, healthBucket, healthState, rul, hi);
if isGlobeAxes
    configureFlightMetadata(surfaceLine, route, engineID, healthBucket, healthState, rul, hi);
end

idx = max(1, min(numel(lat), round(progress * numel(lat))));
trailIdx = max(1, idx - 5);
headingDeg = routeHeadingDegrees(lat, lon, idx);
if isGlobeAxes
    headingLine = geoplot3(routeAxes, lat(1:idx), lon(1:idx), alt(1:idx), '-', ...
        'Color', min(healthColor + 0.25, 1), 'LineWidth', 1.5);
    headingLine = configureGlobeLine(headingLine);
elseif isGeoAxes
    headingLine = geoplot(routeAxes, lat(trailIdx:idx), lon(trailIdx:idx), '-', ...
        'Color', min(healthColor + 0.18, 1), 'LineWidth', 1.5);
else
    headingLine = plot(routeAxes, lon(trailIdx:idx), lat(trailIdx:idx), '-', ...
        'Color', min(healthColor + 0.18, 1), 'LineWidth', 1.5);
end
configureFlightMetadata(headingLine, route, engineID, healthBucket, healthState, rul, hi);

if isGlobeAxes
    aircraftMarker = plotAirplaneIcon(routeAxes, lat(idx), lon(idx), alt(idx) + 18000, ...
        headingDeg, healthColor, sprintf('%s aircraft', engineID), true);
elseif isGeoAxes
    aircraftMarker = plotAirplaneIcon(routeAxes, lat(idx), lon(idx), 0, ...
        headingDeg, healthColor, sprintf('%s aircraft', engineID), false);
else
    aircraftMarker = plotAirplaneIcon(routeAxes, lat(idx), lon(idx), 0, ...
        headingDeg, healthColor, sprintf('%s aircraft', engineID), false);
end
configureFlightMetadataForHandles(aircraftMarker, route, engineID, healthBucket, healthState, rul, hi);

if isGlobeAxes
    originMarker = geoplot3(routeAxes, route.OriginLat, route.OriginLon, 0, 'o', ...
        'Color', min(healthColor + 0.12, 1), 'MarkerSize', 8, 'LineWidth', 1.5);
    originMarker = configureGlobeLine(originMarker);
    configureFlightMetadata(originMarker, route, engineID, healthBucket, healthState, rul, hi);
    destinationMarker = geoplot3(routeAxes, route.DestLat, route.DestLon, 0, 'o', ...
        'Color', min(healthColor + 0.12, 1), 'MarkerSize', 9, 'LineWidth', 1.5);
    destinationMarker = configureGlobeLine(destinationMarker);
elseif isGeoAxes
    originMarker = gobjects(1);
    destinationMarker = geoplot(routeAxes, route.DestLat, route.DestLon, 'o', ...
        'Color', min(healthColor + 0.12, 1), 'MarkerFaceColor', [0.08 0.08 0.10], 'MarkerSize', 4);
else
    originMarker = gobjects(1);
    destinationMarker = plot(routeAxes, route.DestLon, route.DestLat, 'o', ...
        'Color', min(healthColor + 0.12, 1), 'MarkerFaceColor', [0.08 0.08 0.10], 'MarkerSize', 4);
end
configureFlightMetadata(destinationMarker, route, engineID, healthBucket, healthState, rul, hi);

if isGlobeAxes
    handles = [surfaceLine, routeLine, headingLine, aircraftMarker, originMarker, destinationMarker];
else
    handles = [routeLine, headingLine, aircraftMarker, destinationMarker];
end
flightGraphics = struct( ...
    'Handles', handles, ...
    'Route', route, ...
    'HealthBucket', healthBucket);
end

function tf = isRouteGlobe(routeAxes)
tf = isa(routeAxes, 'matlab.graphics.axis.GeographicGlobe') || ...
    contains(class(routeAxes), 'GeographicGlobe');
end

function alt = routeAltitudeProfile(lat, route)
t = linspace(0, 1, numel(lat));
alt = 80000 + 520000 * sin(pi * t);
if string(route.Class) == "Long"
    alt = alt * 1.25;
elseif string(route.Class) == "Medium"
    alt = alt * 1.05;
end
end

function chartObj = configureGlobeLine(chartObj)
try
    if isprop(chartObj, 'HeightReference')
        chartObj.HeightReference = 'geoid';
    end
catch
end
end

function headingDeg = routeHeadingDegrees(lat, lon, idx)
if idx < numel(lat)
    nextIdx = idx + 1;
    prevIdx = idx;
else
    nextIdx = idx;
    prevIdx = max(1, idx - 1);
end

dLat = lat(nextIdx) - lat(prevIdx);
dLon = (lon(nextIdx) - lon(prevIdx)) * max(cosd(lat(idx)), 0.1);
headingDeg = atan2d(dLon, dLat);
end

function handles = plotAirplaneIcon(routeAxes, lat0, lon0, alt0, headingDeg, color, displayName, isGlobeAxes)
if isGlobeAxes
    scaleKm = 150;
else
    scaleKm = 45;
end

[iconLat, iconLon] = airplaneIconCoordinates(lat0, lon0, headingDeg, scaleKm);
if isGlobeAxes
    iconAlt = alt0 + zeros(size(iconLat));
    handles = geoplot3(routeAxes, iconLat, iconLon, iconAlt, '-', 'Color', min(color + 0.12, 1), 'LineWidth', 1.5);
    handles = configureGlobeLine(handles);
elseif isprop(routeAxes, 'Basemap')
    handles = geoplot(routeAxes, iconLat, iconLon, '-', 'Color', min(color + 0.12, 1), 'LineWidth', 1.5, 'DisplayName', displayName);
else
    handles = plot(routeAxes, iconLon, iconLat, '-', ...
        'Color', min(color + 0.12, 1), ...
        'LineWidth', 1.5, ...
        'DisplayName', displayName);
end
end

function [iconLat, iconLon] = airplaneIconCoordinates(lat0, lon0, headingDeg, scaleKm)
shape = [
     0.72,  0.00
    -0.12,  0.30
    -0.06,  0.08
    -0.58,  0.08
    -0.42,  0.00
    -0.58, -0.08
    -0.06, -0.08
    -0.12, -0.30
     0.72,  0.00
      NaN,   NaN
    -0.58,  0.08
    -0.80,  0.20
    -0.68,  0.00
    -0.80, -0.20
    -0.58, -0.08];

forwardKm = shape(:, 1) * scaleKm;
rightKm = shape(:, 2) * scaleKm;
northKm = forwardKm * cosd(headingDeg) - rightKm * sind(headingDeg);
eastKm = forwardKm * sind(headingDeg) + rightKm * cosd(headingDeg);
iconLat = lat0 + northKm / 111.0;
iconLon = lon0 + eastKm ./ (111.0 * max(cosd(lat0), 0.1));
end

function flightGraphics = updateFlightGraphicColor(flightGraphics, healthBucket, healthColor)
if isfield(flightGraphics, 'Handles') && ~isempty(flightGraphics.Handles)
    for i = 1:numel(flightGraphics.Handles)
        if isvalid(flightGraphics.Handles(i))
            if numel(flightGraphics.Handles) >= 6
                if i <= 2
                    flightGraphics.Handles(i).Color = max(healthColor * 0.75, 0.18);
                elseif i == 3
                    flightGraphics.Handles(i).Color = min(healthColor + 0.25, 1);
                else
                    flightGraphics.Handles(i).Color = min(healthColor + 0.12, 1);
                end
            elseif i == 1
                flightGraphics.Handles(i).Color = max(healthColor * 0.70, 0.16);
            elseif i == 2
                flightGraphics.Handles(i).Color = min(healthColor + 0.25, 1);
            else
                flightGraphics.Handles(i).Color = min(healthColor + 0.12, 1);
            end
            if isprop(flightGraphics.Handles(i), 'MarkerFaceColor') && i >= 3
                flightGraphics.Handles(i).MarkerFaceColor = healthColor;
            end
        end
    end
end
flightGraphics.HealthBucket = healthBucket;
end

function flightGraphics = updateFlightGraphicMetadata(flightGraphics, route, engineID, healthBucket, healthState, rul, hi)
if isfield(flightGraphics, 'Handles')
    configureFlightMetadataForHandles(flightGraphics.Handles, route, engineID, healthBucket, healthState, rul, hi);
end
flightGraphics.HealthBucket = healthBucket;
end

function configureFlightMetadataForHandles(handles, route, engineID, healthBucket, healthState, rul, hi)
for i = 1:numel(handles)
    if isvalid(handles(i))
        configureFlightMetadata(handles(i), route, engineID, healthBucket, healthState, rul, hi);
    end
end
end

function configureFlightMetadata(chartObj, route, engineID, healthBucket, healthState, rul, hi)
chartObj.UserData = struct( ...
    'EngineID', string(engineID), ...
    'Origin', route.Origin, ...
    'Destination', route.Destination, ...
    'Direction', route.Direction, ...
    'FlightClass', route.Class, ...
    'DurationHours', route.DurationHours, ...
    'HealthBucket', healthBucket, ...
    'HealthState', healthState, ...
    'RUL', rul, ...
    'HI', hi);

try
    if isprop(chartObj, 'LatitudeData')
        n = max(1, numel(chartObj.LatitudeData));
    elseif isprop(chartObj, 'XData')
        n = max(1, numel(chartObj.XData));
    else
        n = 1;
    end
    chartObj.DataTipTemplate.DataTipRows = [
        dataTipTextRow('Engine', repmat(string(engineID), 1, n))
        dataTipTextRow('Route', repmat(route.Origin + " > " + route.Destination, 1, n))
        dataTipTextRow('Direction', repmat(route.Direction, 1, n))
        dataTipTextRow('Health', repmat(healthBucket, 1, n))
        dataTipTextRow('HI', repmat(string(sprintf('%.2f', hi)), 1, n))
        dataTipTextRow('RUL', repmat(string(formatRULValue(rul)), 1, n))
        dataTipTextRow('Duration', repmat(string(sprintf('%.1f h', route.DurationHours)), 1, n))
        ];
catch
    % Keep UserData available if a MATLAB release rejects custom tip rows.
end
end

function [lat, lon] = routeCurve2D(route)
t = linspace(0, 1, 32);
lat = route.OriginLat + (route.DestLat - route.OriginLat) * t;
lon = route.OriginLon + (route.DestLon - route.OriginLon) * t;
bulge = 0.08 * hypot(route.DestLon - route.OriginLon, route.DestLat - route.OriginLat);
lat = lat + bulge * sin(pi * t);
end

function app = updateRouteCityLabels(app)
if isfield(app, 'routeCityLabels')
    delete(app.routeCityLabels(isvalid(app.routeCityLabels)));
end

if ~isfield(app, 'routeAxes') || ~isvalid(app.routeAxes) || ...
        ~isfield(app, 'routeMapObjects') || app.routeMapObjects.Count == 0
    app.routeCityLabels = gobjects(0);
    return;
end

keysList = app.routeMapObjects.keys;
cities = strings(0, 1);
lats = zeros(0, 1);
lons = zeros(0, 1);
for i = 1:numel(keysList)
    flightGraphics = app.routeMapObjects(keysList{i});
    route = flightGraphics.Route;
    cities = [cities; route.Origin; route.Destination]; %#ok<AGROW>
    lats = [lats; route.OriginLat; route.DestLat]; %#ok<AGROW>
    lons = [lons; route.OriginLon; route.DestLon]; %#ok<AGROW>
end

[uniqueCities, ia] = unique(cities, 'stable');
app.routeCityLabels = gobjects(numel(uniqueCities), 1);
isGlobeAxes = isRouteGlobe(app.routeAxes);
if isGlobeAxes
    app.routeCityLabels = gobjects(0);
    return;
end
isGeoAxes = isprop(app.routeAxes, 'Basemap');
for i = 1:numel(uniqueCities)
    idx = ia(i);
    if isGeoAxes
        app.routeCityLabels(i) = text(app.routeAxes, lats(idx), lons(idx), " " + uniqueCities(i), ...
            'Color', [0.92 0.94 0.96], ...
            'FontSize', 7, ...
            'FontWeight', 'bold', ...
            'BackgroundColor', [0.02 0.025 0.035 0.72], ...
            'Margin', 1, ...
            'Clipping', 'on', ...
            'HitTest', 'off');
    else
        app.routeCityLabels(i) = text(app.routeAxes, lons(idx), lats(idx), " " + uniqueCities(i), ...
            'Color', [0.92 0.94 0.96], ...
            'FontSize', 7, ...
            'FontWeight', 'bold', ...
            'BackgroundColor', [0.02 0.025 0.035 0.72], ...
            'Margin', 1, ...
            'Clipping', 'on', ...
            'HitTest', 'off');
    end
end
end

function app = updateRouteMapLimits(app)
if ~isfield(app, 'routeAxes') || ~isvalid(app.routeAxes)
    return;
end

[latLimits, lonLimits] = indiaRouteMapLimits();
if isRouteGlobe(app.routeAxes)
    try
        campos(app.routeAxes, 21.0, 82.0, 7200000);
        campitch(app.routeAxes, -82);
        camheading(app.routeAxes, 0);
    catch
    end
elseif isprop(app.routeAxes, 'Basemap')
    geolimits(app.routeAxes, latLimits, lonLimits);
    applyTightRouteAxesLayout(app.routeAxes);
else
    xlim(app.routeAxes, lonLimits);
    ylim(app.routeAxes, latLimits);
end
end

function [latLimits, lonLimits] = indiaRouteMapLimits()
latLimits = [5.5 36.5];
lonLimits = [67.0 96.5];
end

function bucket = getFleetHealthBucket(healthState, rul, hi, opState)
if string(opState) == "Maintenance"
    bucket = "MAINT";
elseif string(healthState) == "Healthy"
    bucket = "HEALTHY";
elseif (isfinite(rul) && rul < 20) || hi < 0.20
    bucket = "CRITICAL";
elseif (isfinite(rul) && rul < 50) || hi < 0.50
    bucket = "DEGRADING";
else
    bucket = "EARLY";
end
end

function color = routeHealthColor(bucket)
switch string(bucket)
    case "HEALTHY"
        color = [0.25 0.90 0.45];
    case "CRITICAL"
        color = [1.00 0.24 0.22];
    case "DEGRADING"
        color = [1.00 0.68 0.16];
    case "MAINT"
        color = [0.62 0.62 0.68];
    otherwise
        color = [0.38 0.68 1.00];
end
end

function text = formatRULValue(rul)
if isfinite(rul)
    text = sprintf("%.0f", rul);
else
    text = "--";
end
end

function app = buildEngineDetailPanel(app, parentGrid)
detPanel = uipanel(parentGrid, 'Title', 'SELECTED ENGINE', ...
    'BackgroundColor', [0.12 0.12 0.14], ...
    'ForegroundColor', [0.4 0.9 0.6], ...
    'FontWeight', 'bold', 'FontSize', 16);
detPanel.Layout.Row = 1;

g = uigridlayout(detPanel, [7 1]);
g.RowHeight = {30, 40, 22, 22, 22, 35, '1x'};
g.Padding = [8 8 8 8];
g.RowSpacing = 2;
g.BackgroundColor = [0.12 0.12 0.14];

% Engine dropdown
app.engineDropdown = uidropdown(g, ...
    'Items', cellstr(app.mwIDs), ...
    'Value', char(app.mwIDs(1)), ...
    'FontSize', 12, ...
    'BackgroundColor', [0.18 0.18 0.22], ...
    'FontColor', [0.3 0.8 1], ...
    'ValueChangedFcn', @(src,~) engineSelected(src, app.fig));

% Fault mode — BIG
app.detailHealth = uilabel(g, 'Text', 'Waiting...', ...
    'FontSize', 18, 'FontWeight', 'bold', ...
    'FontColor', [0.7 0.8 0.9]);

app.detailState = uilabel(g, 'Text', 'Op State: --', ...
    'FontSize', 12, 'FontColor', [0.5 0.6 0.7]);

app.detailConf = uilabel(g, 'Text', 'Confidence: --', ...
    'FontSize', 12, 'FontColor', [0.5 0.6 0.7]);

app.detailHI = uilabel(g, 'Text', 'HI: --', ...
    'FontSize', 12, 'FontColor', [0.5 0.6 0.7]);

% RUL — BIG
app.detailRUL = uilabel(g, 'Text', 'RUL: --', ...
    'FontSize', 16, 'FontWeight', 'bold', ...
    'FontColor', [0.7 0.8 0.9]);

app.detailNotes = uitextarea(g, 'Value', {'Loading selected engine snapshot...'}, ...
    'FontName', 'Consolas', 'FontSize', 12, ...
    'FontColor', [0.68 0.76 0.84], ...
    'BackgroundColor', [0.08 0.08 0.10], ...
    'Editable', false);
end

function app = buildPlotPanel(app, parentGrid)
plotPanel = uipanel(parentGrid, 'Title', 'ENGINE TREND', ...
    'BackgroundColor', [0.12 0.12 0.14], ...
    'ForegroundColor', [0.9 0.6 0.3], ...
    'FontWeight', 'bold', 'FontSize', 16);
plotPanel.Layout.Row = 2;

g = uigridlayout(plotPanel, [3 1]);
g.RowHeight = {30, 22, '1x'};
g.Padding = [8 8 8 8];
g.RowSpacing = 4;
g.BackgroundColor = [0.12 0.12 0.14];

% Radio button group for RUL vs HI
bg = uibuttongroup(g, 'BackgroundColor', [0.12 0.12 0.14], ...
    'ForegroundColor', [0.7 0.8 0.9], 'BorderType', 'none', ...
    'SelectionChangedFcn', @(~,~) plotModeChanged(app.fig));

app.radioRUL = uiradiobutton(bg, 'Text', 'RUL Trend', ...
    'Position', [10 5 120 20], ...
    'FontSize', 11, 'FontColor', [0.8 0.8 0.9], 'Value', true);
app.radioHI = uiradiobutton(bg, 'Text', 'Health Indicator', ...
    'Position', [140 5 150 20], ...
    'FontSize', 11, 'FontColor', [0.8 0.8 0.9]);

% X-axis toggle: Ticks vs Cycles
xg = uigridlayout(g, [1 2]);
xg.ColumnWidth = {80, 80};
xg.Padding = [0 0 0 0];
xg.BackgroundColor = [0.12 0.12 0.14];
app.xAxisCycles = uicheckbox(xg, 'Text', 'Cycles', ...
    'FontSize', 10, 'FontColor', [0.7 0.8 0.9], 'Value', true, ...
    'ValueChangedFcn', @(~,~) plotModeChanged(app.fig));
uilabel(xg, 'Text', '(uncheck = ticks)', 'FontSize', 9, ...
    'FontColor', [0.5 0.5 0.6]);

% Axes
app.trendAxes = uiaxes(g);
app.trendAxes.Color = [0.08 0.08 0.10];
app.trendAxes.XColor = [0.5 0.5 0.6];
app.trendAxes.YColor = [0.5 0.5 0.6];
app.trendAxes.GridColor = [0.2 0.2 0.25];
app.trendAxes.GridAlpha = 0.5;
app.trendAxes.Box = 'on';
try
    axtoolbar(app.trendAxes, {'restoreview', 'zoomin', 'zoomout', 'pan'});
    app.trendAxes.Toolbar.Visible = 'on';
catch
    app.trendAxes.Toolbar.Visible = 'on';
end
grid(app.trendAxes, 'on');
end

%% ========================================================================
%  RENDERING FUNCTIONS
%  ========================================================================
function renderClusters(fig)
renderClustersSelective(fig, true(6,1));
end

function renderClustersSelective(fig, clusterMask)
app = fig.UserData;
fleet = app.fleet;

CARD_W = 72;
CARD_H = 52;
PAD = 2;
GAP = 2;

for s = 1:6
    if ~clusterMask(s), continue; end

    innerPanel = app.clusterPanels(s);
    delete(innerPanel.Children);

    idx = fleet.OpState == app.stateNames(s);
    engines = fleet(idx, :);
    n = height(engines);

    if n == 0
        app.clusterGrids(s) = gobjects(1);
        continue;
    end

    cols = max(2, min(4, ceil(sqrt(n * 1.4))));
    rows = ceil(n / cols);

    totalH = PAD * 2 + rows * CARD_H + (rows - 1) * GAP;
    panelPos = innerPanel.Position;
    panelH = max(panelPos(4), totalH);
    app.clusterGrids(s) = gobjects(1);

    isMaint = (app.stateNames(s) == "Maintenance");

    for e = 1:n
        r = floor((e-1) / cols) + 1;
        c = mod(e-1, cols) + 1;

        hs = engines.HealthState(e);
        hi = engines.HI(e);
        rul = engines.RUL(e);

        [borderClr, bgClr, textClr] = getCardColors(isMaint, hs, rul, hi);

        % Position: top-down (y=0 is bottom in MATLAB, so top row has highest y)
        xPos = PAD + (c - 1) * (CARD_W + GAP);
        yPos = panelH - PAD - r * CARD_H - (r - 1) * GAP;
        cardSelectFcn = @(~,~) engineCardClicked(fig, engines.ID(e));

        card = uipanel(innerPanel, 'BorderType', 'line', 'BackgroundColor', bgClr, ...
                       'HighlightColor', borderClr, 'BorderWidth', 1.5, ...
                       'Position', [xPos, yPos, CARD_W, CARD_H]);

        cardGrid = uigridlayout(card, [3 1]);
        cardGrid.RowHeight = {16, 14, 14};
        cardGrid.Padding = [3 1 3 1];
        cardGrid.RowSpacing = 0;
        cardGrid.BackgroundColor = bgClr;

        idColor = min(borderClr * 1.3, 1);
        lblID = uilabel(cardGrid, 'Text', engines.ID(e), ...
            'FontSize', 12, 'FontWeight', 'bold', 'FontColor', idColor);

        if hs == "Healthy"
            modeStr = "OK";
        else
            modeStr = hs;
        end
        lblMode = uilabel(cardGrid, 'Text', modeStr, ...
            'FontSize', 10, 'FontWeight', 'bold', 'FontColor', borderClr);
        lblMode.Layout.Row = 2;

        if isMaint
            rulStr = "MAINT";
        else
            rulStr = formatRUL(rul);
        end
        lblHI = uilabel(cardGrid, 'Text', rulStr, ...
            'FontSize', 10, 'FontColor', textClr * 0.8);
        lblHI.Layout.Row = 3;

        card.ButtonDownFcn = cardSelectFcn;

        cardInfo = struct('panel', card, 'lblID', lblID, ...
            'lblMode', lblMode, 'lblHI', lblHI);
        app.cardHandles(char(engines.ID(e))) = cardInfo;
    end
end

fig.UserData = app;
end

function updateClusterTitles(fig)
app = fig.UserData;
fleet = app.fleet;
for s = 1:6
    n = sum(fleet.OpState == app.stateNames(s));
    app.clusterTitles(s).Text = sprintf("[%d] %s", n, app.stateNames(s));
end
end

function [borderClr, bgClr, textClr] = getCardColors(isMaint, hs, rul, hi)
if isMaint
    borderClr = [0.45 0.45 0.50];
    bgClr = [0.15 0.15 0.17];
    textClr = [0.65 0.65 0.70];
elseif hs == "Healthy"
    borderClr = [0.2 0.75 0.35];
    bgClr = [0.08 0.16 0.10];
    textClr = [0.6 0.8 0.65];
elseif (isfinite(rul) && rul < 20) || hi < 0.20
    borderClr = [0.9 0.2 0.2];
    bgClr = [0.2 0.08 0.08];
    textClr = [0.9 0.6 0.5];
elseif (isfinite(rul) && rul < 50) || hi < 0.50
    borderClr = [0.9 0.6 0.1];
    bgClr = [0.18 0.14 0.06];
    textClr = [0.8 0.7 0.5];
else
    borderClr = [0.3 0.6 0.8];
    bgClr = [0.10 0.13 0.18];
    textClr = [0.6 0.7 0.8];
end
end

function updateCardsInPlace(fig, tickIDs, changedClusters)
app = fig.UserData;
for i = 1:numel(tickIDs)
    key = char(tickIDs(i));
    if ~app.cardHandles.isKey(key), continue; end
    ci = app.cardHandles(key);
    if ~isvalid(ci.panel), continue; end

    engIdx = find(app.fleet.ID == tickIDs(i));
    if isempty(engIdx), continue; end

    % Skip engines in clusters that were already fully rebuilt
    stateIdx = find(app.stateNames == app.fleet.OpState(engIdx));
    if ~isempty(stateIdx) && changedClusters(stateIdx), continue; end

    hs = app.fleet.HealthState(engIdx);
    hi = app.fleet.HI(engIdx);
    rul = app.fleet.RUL(engIdx);
    isMaint = (app.fleet.OpState(engIdx) == "Maintenance");

    [borderClr, bgClr, textClr] = getCardColors(isMaint, hs, rul, hi);

    ci.panel.BackgroundColor = bgClr;
    ci.panel.HighlightColor = borderClr;

    ci.lblID.FontColor = min(borderClr * 1.3, 1);
    if hs == "Healthy"
        ci.lblMode.Text = "OK";
    else
    ci.lblMode.Text = char(hs);
    end
    ci.lblMode.FontColor = borderClr;
    if isMaint
        ci.lblHI.Text = "MAINT";
    else
        ci.lblHI.Text = formatRUL(rul);
    end
    ci.lblHI.FontColor = textClr * 0.8;
end
end


function updateKPIs(fig)
app = fig.UserData;
fleet = app.fleet;

isOperational = fleet.OpState ~= "Maintenance";
isCritical = ((isfinite(fleet.RUL) & fleet.RUL < 20) | fleet.HI < 0.20) & ...
    fleet.HealthState ~= "Healthy";
isDegrading = isOperational & fleet.HealthState ~= "Healthy" & ...
    ~isCritical & ((isfinite(fleet.RUL) & fleet.RUL < 50) | fleet.HI < 0.50);
isEarlyFailure = isOperational & fleet.HealthState ~= "Healthy" & ...
    ~isCritical & ~isDegrading;
nHealthy = sum(isOperational & fleet.HealthState == "Healthy");
nCritical = sum(isCritical & isOperational);
nDegrading = sum(isDegrading);
nEarlyFailure = sum(isEarlyFailure);
nMaint = sum(fleet.OpState == "Maintenance");

app.kpiTotal.Text = string(app.nEngines);
app.kpiHealthy.Text = string(nHealthy);
app.kpiFaulted.Text = string(nDegrading);
app.kpiCritical.Text = string(nCritical);
app.kpiAirborne.Text = string(nEarlyFailure);
app.kpiMaint.Text = string(nMaint);

% Flight class distribution
fcNames = ["Short","Medium","Long"];
fcLines = strings(3, 1);
for i = 1:3
    subset = fleet(fleet.FlightClass == fcNames(i), :);
    nH = sum(subset.HealthState == "Healthy");
    nF = height(subset) - nH;
    fcLines(i) = sprintf("  %-7s: %2d engines (H:%d F:%d)", fcNames(i), height(subset), nH, nF);
end
app.flightClassList.Value = [{'FLIGHT CLASS'}; cellstr(fcLines)];

% Fault distribution
modes = unique(fleet.HealthState);
lines = strings(numel(modes), 1);
for i = 1:numel(modes)
    n = sum(fleet.HealthState == modes(i));
    lines(i) = sprintf("  %-12s: %2d", modes(i), n);
end
app.faultDistList.Value = [{'FAULT MODES'}; cellstr(lines)];

% Top risk engines (lowest RUL, excluding healthy and maintenance)
atRisk = fleet((isCritical & isOperational) | isDegrading, :);
if ~isempty(atRisk)
    atRisk = sortrows(atRisk, {'RUL', 'HI'}, {'ascend', 'ascend'});
    topN = min(10, height(atRisk));
    riskLines = strings(topN, 1);
    for i = 1:topN
        riskLines(i) = sprintf("%s | %s | %s | HI:%.2f", ...
            atRisk.ID(i), atRisk.HealthState(i), formatRUL(atRisk.RUL(i)), atRisk.HI(i));
    end
    app.riskList.Value = cellstr(riskLines);
else
    app.riskList.Value = {'No at-risk engines'};
end

app = updateConnectionStatusUI(app);
fig.UserData = app;
end

function updateSelectedEngine(fig)
app = fig.UserData;
engID = app.selectedEngine;
engIdx = find(app.fleet.ID == engID);
if isempty(engIdx), return; end

eng = app.fleet(engIdx, :);
isCriticalEngine = (isfinite(eng.RUL) && eng.RUL < 20) || eng.HI < 0.20;
[originCity, destinationCity] = getEngineRoute(eng.ID, eng.FlightClass, eng.CycleCount);
maintenanceText = formatMaintenanceRecency(eng.CycleCount, eng.LastMaintenanceCycle);
opText = formatOperationalStatus(eng.OpState);

app.detailState.Text = "Op State: " + eng.OpState;

if eng.HealthState == "Healthy"
    app.detailHealth.Text = "HEALTHY";
    app.detailHealth.FontColor = [0.2 1 0.4];
elseif eng.HealthState == "All"
    app.detailHealth.Text = "ALL MODES";
    if (isfinite(eng.RUL) && eng.RUL < 20) || eng.HI < 0.20
        app.detailHealth.FontColor = [1 0.2 0.2];
    else
        app.detailHealth.FontColor = [1 0.5 0.1];
    end
else
    app.detailHealth.Text = eng.HealthState;
    if (isfinite(eng.RUL) && eng.RUL < 20) || eng.HI < 0.20
        app.detailHealth.FontColor = [1 0.3 0.3];
    else
        app.detailHealth.FontColor = [1 0.7 0.2];
    end
end

app.detailConf.Text = sprintf("Confidence: %.1f%%", eng.Confidence * 100);
app.detailHI.Text = sprintf("HI: %.2f", eng.HI);

if eng.OpState == "Maintenance"
    app.detailRUL.Text = "RUL: IN MAINTENANCE";
    app.detailRUL.FontColor = [0.6 0.6 0.65];
    actionText = "Maintenance active; wait for recovery reset.";
else
    app.detailRUL.Text = formatRUL(eng.RUL);
    if isCriticalEngine
        app.detailRUL.FontColor = [1 0.3 0.3];
        actionText = "Critical: MRO team notified.";
    elseif (isfinite(eng.RUL) && eng.RUL < 50) || eng.HI < 0.50
        app.detailRUL.FontColor = [1 0.7 0.2];
        actionText = "Degrading: schedule maintenance window.";
    else
        app.detailRUL.FontColor = [0.3 0.9 0.5];
        if eng.HealthState == "Healthy"
            actionText = "Nominal: continue routine monitoring.";
        else
            actionText = "Early signal: monitor trend and confidence.";
        end
    end
end

app.detailNotes.Value = [
    "Assessment: " + actionText
    "Operational: " + opText
    "Last trip: " + originCity + " to " + destinationCity
    "Last maintenance: " + maintenanceText
    "Flight class: " + string(eng.FlightClass)
    "Completed flights: " + string(eng.CycleCount)
    "Model updates: " + string(eng.TicksSeen)
    "Snapshot tick: " + string(app.tickIndex)
    ];

fig.UserData = app;

% Update plot
plotEngineTrend(fig);
end

function plotEngineTrend(fig)
app = fig.UserData;
ax = app.trendAxes;
cla(ax);
hold(ax, 'on');

key = char(app.selectedEngine);
showRUL = app.radioRUL.Value;
useCycles = app.xAxisCycles.Value;

if showRUL
    data = app.rulHistory(key);
    if isempty(data)
        title(ax, 'RUL — No data yet', 'Color', [0.8 0.8 0.9], 'FontSize', 11);
        hold(ax, 'off');
        return;
    end
    [xVals, data, xLabel] = prepareTrendSeries(app, key, data, useCycles);
    plot(ax, xVals, data, '-o', 'Color', [0.3 0.7 1], ...
        'MarkerSize', 4, 'MarkerFaceColor', [0.3 0.7 1], 'LineWidth', 1.5);
    finiteData = data(isfinite(data));
    if isempty(finiteData)
        ylim(ax, [0 1]);
    else
        ylim(ax, [0 max(20, max(finiteData) * 1.1)]);
    end
    title(ax, sprintf('RUL Trend — %s', key), 'Color', [0.8 0.8 0.9], 'FontSize', 11);
    xlabel(ax, xLabel, 'Color', [0.6 0.6 0.7]);
    ylabel(ax, 'RUL (cycles)', 'Color', [0.6 0.6 0.7]);
else
    data = app.hiHistory(key);
    if isempty(data)
        title(ax, 'HI — No data yet', 'Color', [0.8 0.8 0.9], 'FontSize', 11);
        hold(ax, 'off');
        return;
    end
    [xVals, data, xLabel] = prepareTrendSeries(app, key, data, useCycles);
    plotPhaseColoredHI(ax, xVals, data);
    ylim(ax, [0 1.1]);

    engIdx = find(app.fleet.ID == app.selectedEngine);
    mode = char(app.fleet.HealthState(engIdx));
    thresh = getModeThreshold(mode);
    if ~isnan(thresh)
        yline(ax, thresh, '--r', 'LineWidth', 1.5, ...
            'Label', sprintf('Threshold (%.2f)', thresh), ...
            'LabelColor', [1 0.4 0.4], 'FontSize', 9);
    end

    yline(ax, 0.80, ':', 'Color', [0.25 0.9 0.35], 'LineWidth', 1.1);
    yline(ax, 0.50, ':', 'Color', [0.35 0.65 0.95], 'LineWidth', 1.1);
    yline(ax, 0.20, ':', 'Color', [0.95 0.25 0.20], 'LineWidth', 1.1);

    title(ax, sprintf('Health Indicator — %s', key), 'Color', [0.8 0.8 0.9], 'FontSize', 11);
    xlabel(ax, xLabel, 'Color', [0.6 0.6 0.7]);
    ylabel(ax, 'HI (0–1)', 'Color', [0.6 0.6 0.7]);
end

hold(ax, 'off');
end

function plotPhaseColoredHI(ax, xVals, data)
if isscalar(data)
    clr = getHIPhaseColor(data(1));
    plot(ax, xVals, data, 'o', 'Color', clr, ...
        'MarkerSize', 5, 'MarkerFaceColor', clr, 'LineWidth', 1.5);
    return;
end

for idx = 1:(numel(data) - 1)
    ySegment = data(idx:idx+1);
    xSegment = xVals(idx:idx+1);
    clr = getHIPhaseColor(mean(ySegment, 'omitnan'));
    plot(ax, xSegment, ySegment, '-o', 'Color', clr, ...
        'MarkerSize', 4, 'MarkerFaceColor', clr, 'LineWidth', 1.6);
end
end

function clr = getHIPhaseColor(hi)
if hi >= 0.80
    clr = [0.25 0.9 0.35];
elseif hi >= 0.50
    clr = [0.35 0.65 0.95];
elseif hi >= 0.20
    clr = [0.95 0.65 0.15];
else
    clr = [0.95 0.25 0.20];
end
end

function [xVals, data, xLabel] = prepareTrendSeries(app, key, data, useCycles)
if useCycles && app.cycleHistory.isKey(key)
    xVals = app.cycleHistory(key);
    xLabel = 'Cycles (latest observation per flight cycle)';
    if numel(xVals) == numel(data)
        [xVals, lastIdx] = unique(xVals, 'last');
        data = data(lastIdx);
    else
        xVals = 1:numel(data);
        xLabel = 'Observation';
    end
elseif isfield(app, 'tickHistory') && app.tickHistory.isKey(key)
    xVals = app.tickHistory(key);
    xLabel = 'Dashboard tick';
    if numel(xVals) ~= numel(data)
        xVals = 1:numel(data);
        xLabel = 'Observation';
    end
else
    xVals = 1:numel(data);
    xLabel = 'Observation';
end
end

%% ========================================================================
%  CALLBACKS
%  ========================================================================
function engineCardClicked(fig, engineID)
if ~isvalid(fig), return; end
app = fig.UserData;
app.selectedEngine = engineID;
app.engineDropdown.Value = char(engineID);
fig.UserData = app;
updateSelectedEngine(fig);
drawnow;
end

function engineSelected(src, fig)
if ~isvalid(fig), return; end
app = fig.UserData;
app.selectedEngine = string(src.Value);
fig.UserData = app;
updateSelectedEngine(fig);
drawnow;
end

function plotModeChanged(fig)
if isvalid(fig)
    plotEngineTrend(fig);
end
end

function updateRefreshRate(src)
fig = ancestor(src, 'figure');
app = fig.UserData;
newPeriod = src.Value;
app.refreshPeriod = newPeriod;
if ~canUseRouteGlobe(app) && app.routeDisplayMode == "Globe"
    app.routeDisplayMode = "2D";
    app = rebuildRouteMap(app);
end
app = updateRouteViewControlState(app);
if app.serviceAvailable
    app = updateStreamTimerPeriod(app, newPeriod);
else
    app = updateStreamTimerPeriod(app, app.reconnectPeriod);
end
app = updateConnectionStatusUI(app);
fig.UserData = app;
if isRouteMapVisible(app) && app.routeMapNeedsRender
    scheduleRouteMapRender(fig);
end
end

function updateServiceEndpoint(src)
fig = ancestor(src, 'figure');
if ~isvalid(fig), return; end

app = fig.UserData;
app = configureServiceEndpoint(app, string(src.Value));
app.lastConnectionError = "";

[isAvailable, message] = checkMicroserviceHealth(app);
app.serviceAvailable = isAvailable;
if isAvailable
    app.connectionMessage = sprintf('%s connected', char(app.serviceDisplayName));
    app = updateStreamTimerPeriod(app, app.refreshPeriod);
else
    app.connectionMessage = "Connection failure - displaying last known fleet status";
    app.lastConnectionError = message;
    app = updateStreamTimerPeriod(app, app.reconnectPeriod);
end

app = updateConnectionStatusUI(app);
fig.UserData = app;
persistDashboardSnapshot(app);
drawnow;
end

function updateRouteDisplayMode(src)
fig = ancestor(src, 'figure');
app = fig.UserData;
requestedMode = string(src.Value);
if requestedMode == "Globe" && ~canUseRouteGlobe(app)
    requestedMode = "2D";
end
app.routeDisplayMode = requestedMode;
app = updateRouteViewControlState(app);
app = rebuildRouteMap(app);
fig.UserData = app;
if isRouteMapVisible(app)
    scheduleRouteMapRender(fig);
end
end

function resetPlaybackFromControl(src)
fig = ancestor(src, 'figure');
if ~isvalid(fig), return; end

app = fig.UserData;
wasRunning = isfield(app, 'streamTimer') && isa(app.streamTimer, 'timer') && ...
    isvalid(app.streamTimer) && strcmp(app.streamTimer.Running, 'on');
if wasRunning
    stop(app.streamTimer);
end

flightClasses = app.fleet.FlightClass;
selectedEngine = app.selectedEngine;
app = initializeFleetPlaybackState(app, flightClasses);
if any(app.fleet.ID == selectedEngine)
    app.selectedEngine = selectedEngine;
end

[isAvailable, message] = checkMicroserviceHealth(app);
app.serviceAvailable = isAvailable;
if isAvailable
    try
        app = applyAnalyticsTick(app, 1);
        app.tickIndex = 1;
        app.connectionMessage = "Microservice connected - playback reset to tick 1";
        app = updateStreamTimerPeriod(app, app.refreshPeriod);
    catch ME
        app.serviceAvailable = false;
        app.connectionMessage = "Connection failure during reset - displaying initialized fleet status";
        app.lastConnectionError = ME.message;
        app = updateStreamTimerPeriod(app, app.reconnectPeriod);
    end
else
    app.connectionMessage = "Connection failure during reset - displaying initialized fleet status";
    app.lastConnectionError = message;
    app = updateStreamTimerPeriod(app, app.reconnectPeriod);
end

app.cardHandles = containers.Map();
fig.UserData = app;
renderClusters(fig);
updateKPIs(fig);
updateSelectedEngine(fig);
app = fig.UserData;
app.routeMapNeedsRender = true;
app = updateConnectionStatusUI(app);
fig.UserData = app;
persistDashboardSnapshot(app);
if isRouteMapVisible(app)
    scheduleRouteMapRender(fig);
end
if wasRunning && isvalid(app.streamTimer)
    start(app.streamTimer);
end
drawnow;
end

function tf = canUseRouteGlobe(app)
tf = ~app.isOfflineMode && app.refreshPeriod >= 20 && ...
    exist('geoglobe', 'file') == 2 && exist('geoplot3', 'file') == 2;
end

function app = updateRouteViewControlState(app)
app.routeGlobeEnabled = canUseRouteGlobe(app);
if isfield(app, 'mapViewDropdown') && isvalid(app.mapViewDropdown)
    if ~app.routeGlobeEnabled && app.routeDisplayMode == "Globe"
        app.routeDisplayMode = "2D";
    end
    app.mapViewDropdown.Value = char(app.routeDisplayMode);
    if app.routeGlobeEnabled
        app.mapViewDropdown.Enable = 'on';
        app.mapViewDropdown.Tooltip = '3D route view is available at refresh rates of 20 seconds or slower.';
    elseif app.isOfflineMode
        app.mapViewDropdown.Enable = 'off';
        app.mapViewDropdown.Tooltip = 'Offline mode disables mapping-toolbox and 3D map views.';
    else
        app.mapViewDropdown.Enable = 'off';
        app.mapViewDropdown.Tooltip = 'Increase refresh rate to 20 seconds or more to enable 3D route view.';
    end
end
end

function app = rebuildRouteMap(app)
if ~isfield(app, 'routeMapParent') || ~isvalid(app.routeMapParent)
    return;
end
if isfield(app, 'routeMapObjects') && isa(app.routeMapObjects, 'containers.Map')
    keysList = app.routeMapObjects.keys;
    for i = 1:numel(keysList)
        deleteFlightGraphics(app.routeMapObjects(keysList{i}));
    end
end
app = buildRouteMap(app, app.routeMapParent);
app.routeMapNeedsRender = true;
end

function cleanupDashboard(fig)
app = fig.UserData;
if isfield(app, 'streamTimer') && isvalid(app.streamTimer)
    stop(app.streamTimer);
end
if isfield(app, 'routeRenderTimer') && isa(app.routeRenderTimer, 'timer') && isvalid(app.routeRenderTimer)
    stop(app.routeRenderTimer);
end
persistDashboardSnapshot(app);
if isfield(app, 'streamTimer') && isvalid(app.streamTimer)
    delete(app.streamTimer);
end
if isfield(app, 'routeRenderTimer') && isa(app.routeRenderTimer, 'timer') && isvalid(app.routeRenderTimer)
    delete(app.routeRenderTimer);
end
delete(fig);
end

function persistDashboardSnapshot(app)
if ~isfield(app, 'snapshotPath') || strlength(string(app.snapshotPath)) == 0
    return;
end

jarvisSnapshot = struct();
jarvisSnapshot.mwIDs = app.mwIDs;
jarvisSnapshot.faultClasses = app.fleet.HealthState;
jarvisSnapshot.confidence = app.fleet.Confidence;
jarvisSnapshot.rulValues = app.fleet.RUL;
jarvisSnapshot.hiValues = app.fleet.HI;
jarvisSnapshot.opStates = app.fleet.OpState;
jarvisSnapshot.tickIndex = app.tickIndex;
jarvisSnapshot.timestamp = datetime('now');
jarvisSnapshot.serviceEndpoint = app.serviceEndpoint;
jarvisSnapshot.microserviceUrl = string(app.microserviceUrl);

isOperational = app.fleet.OpState ~= "Maintenance";
isCritical = ((isfinite(app.fleet.RUL) & app.fleet.RUL < 20) | app.fleet.HI < 0.20) & ...
    app.fleet.HealthState ~= "Healthy";
isDegrading = isOperational & app.fleet.HealthState ~= "Healthy" & ...
    ~isCritical & ((isfinite(app.fleet.RUL) & app.fleet.RUL < 50) | app.fleet.HI < 0.50);
isEarlyFailure = isOperational & app.fleet.HealthState ~= "Healthy" & ...
    ~isCritical & ~isDegrading;
jarvisSnapshot.summary = struct( ...
    'nTotal', height(app.fleet), ...
    'nHealthy', sum(isOperational & app.fleet.HealthState == "Healthy"), ...
    'nFaulted', sum(app.fleet.HealthState ~= "Healthy"), ...
    'nDegrading', sum(isDegrading), ...
    'nCritical', sum(isCritical & isOperational), ...
    'nEarlyFailure', sum(isEarlyFailure), ...
    'nAirborne', sum(app.fleet.OpState == "Airborne"), ...
    'nMaintenance', sum(app.fleet.OpState == "Maintenance"));

dashboardState = struct();
dashboardState.schemaVersion = 3;
dashboardState.tickIndex = app.tickIndex;
dashboardState.fleet = app.fleet;
dashboardState.hiHistory = app.hiHistory;
dashboardState.rulHistory = app.rulHistory;
dashboardState.cycleHistory = app.cycleHistory;
dashboardState.tickHistory = app.tickHistory;
dashboardState.selectedEngine = app.selectedEngine;
dashboardState.timestamp = jarvisSnapshot.timestamp;
dashboardState.dashboardMode = app.dashboardMode;
dashboardState.routeDisplayMode = app.routeDisplayMode;
dashboardState.refreshPeriod = app.refreshPeriod;
dashboardState.serviceEndpoint = app.serviceEndpoint;
dashboardState.microserviceUrl = string(app.microserviceUrl);
if isfield(app, 'serviceAvailable')
    dashboardState.serviceAvailable = app.serviceAvailable;
end
if isfield(app, 'connectionMessage')
    dashboardState.connectionMessage = app.connectionMessage;
end

tempSnapshotPath = app.snapshotPath + ".tmp";
try
    save(tempSnapshotPath, 'jarvisSnapshot', 'dashboardState');
    movefile(tempSnapshotPath, app.snapshotPath, 'f');
catch ME
    if isfile(tempSnapshotPath)
        delete(tempSnapshotPath);
    end
    warning('EngineFleetDashboard:SnapshotSaveFailed', ...
        'Failed to persist dashboard snapshot: %s', ME.message);
end
end

%% ========================================================================
%  HELPERS
%  ========================================================================
function thresh = getModeThreshold(mode)
threshMap = containers.Map( ...
    {'HPT','LPT','HPT + LPT','Fan','HPC','HPC + LPC'}, ...
    {0, -0.1, -0.05, 0.05, 0, 0});
if threshMap.isKey(mode)
    thresh = threshMap(mode);
else
    thresh = NaN;
end
end

function tf = isCriticalForMaintenance(rul, hi)
tf = (~isfinite(rul) && hi <= 0.05) || (isfinite(rul) && rul <= 10) || hi <= 0.02;
end

function tf = shouldEnterMaintenance(app, engIdx)
tf = isCriticalForMaintenance(app.fleet.RUL(engIdx), app.fleet.HI(engIdx)) && ...
    isNewCycleSinceMaintenance(app, engIdx);
end

function tf = isNewCycleSinceMaintenance(app, engIdx)
if ~ismember('LastMaintenanceCycle', app.fleet.Properties.VariableNames)
    tf = true;
    return;
end

lastCycle = app.fleet.LastMaintenanceCycle(engIdx);
tf = ~isfinite(lastCycle) || app.fleet.CycleCount(engIdx) > lastCycle;
end

function ticks = maintenanceDurationTicks(app)
batchSize = 9;
ticks = 3 * ceil(app.nEngines / batchSize);
end

function [originCity, destinationCity] = getEngineRoute(engineID, flightClass, cycleCount)
[shortRoutes, mediumRoutes, longRoutes] = getRouteLibraries();
switch string(flightClass)
    case "Short"
        routeTable = shortRoutes;
    case "Medium"
        routeTable = mediumRoutes;
    otherwise
        routeTable = longRoutes;
end

seed = sum(double(char(string(engineID)))) + round(double(cycleCount));
routeIdx = mod(seed - 1, height(routeTable)) + 1;
originCity = routeTable.Origin(routeIdx);
destinationCity = routeTable.Destination(routeIdx);
end

function text = formatMaintenanceRecency(cycleCount, lastMaintenanceCycle)
if ~isfinite(lastMaintenanceCycle)
    text = "not yet recorded in playback";
    return;
end

cyclesAgo = max(0, round(cycleCount - lastMaintenanceCycle));
if cyclesAgo == 0
    text = "current cycle";
elseif cyclesAgo == 1
    text = "1 cycle ago";
else
    text = string(cyclesAgo) + " cycles ago";
end
end

function text = formatOperationalStatus(opState)
switch string(opState)
    case "Airborne"
        text = "Airborne";
    case "Just Landed"
        text = "Just landed";
    case "Departure 0-2h"
        text = "Scheduled for departure in next 0-2 h";
    case "Departure 2-6h"
        text = "Scheduled for departure in next 2-6 h";
    case "Ground Idle"
        text = "Ground idle";
    case "Maintenance"
        text = "In maintenance";
    otherwise
        text = string(opState);
end
end

function [shortRoutes, mediumRoutes, longRoutes] = getRouteLibraries()
shortRoutes = table( ...
    ["Delhi";"Delhi";"Mumbai";"Mumbai";"Bengaluru";"Bengaluru";"Chennai";"Chennai";"Hyderabad";"Hyderabad";"Kolkata";"Kolkata";"Ahmedabad";"Pune";"Jaipur";"Lucknow";"Kochi";"Guwahati";"Indore";"Bhubaneswar";"Nagpur";"Coimbatore";"Visakhapatnam";"Goa";"Srinagar"], ...
    ["Jaipur";"Lucknow";"Goa";"Indore";"Hyderabad";"Kochi";"Coimbatore";"Madurai";"Visakhapatnam";"Pune";"Guwahati";"Bhubaneswar";"Udaipur";"Nagpur";"Jodhpur";"Varanasi";"Thiruvananthapuram";"Imphal";"Raipur";"Ranchi";"Bhopal";"Mangaluru";"Vijayawada";"Mangaluru";"Leh"], ...
    'VariableNames', {'Origin','Destination'});

mediumRoutes = table( ...
    ["Delhi";"Delhi";"Delhi";"Mumbai";"Mumbai";"Mumbai";"Bengaluru";"Bengaluru";"Bengaluru";"Chennai";"Chennai";"Hyderabad";"Hyderabad";"Kolkata";"Kolkata";"Ahmedabad";"Kochi";"Goa";"Pune";"Jaipur";"Lucknow";"Guwahati";"Delhi";"Mumbai";"Bengaluru";"Chennai";"Hyderabad";"Kolkata";"Ahmedabad";"Kochi";"Pune";"Delhi";"Mumbai"], ...
    ["Kathmandu";"Dhaka";"Dubai";"Dubai";"Muscat";"Doha";"Colombo";"Male";"Muscat";"Colombo";"Kuala Lumpur";"Dubai";"Doha";"Dhaka";"Bangkok";"Dubai";"Dubai";"Dubai";"Dubai";"Dubai";"Muscat";"Bangkok";"Muscat";"Kuwait City";"Doha";"Singapore";"Riyadh";"Singapore";"Doha";"Doha";"Abu Dhabi";"Bahrain";"Bahrain"], ...
    'VariableNames', {'Origin','Destination'});

longRoutes = table( ...
    ["Delhi";"Delhi";"Delhi";"Mumbai";"Mumbai";"Mumbai";"Bengaluru";"Bengaluru";"Bengaluru";"Chennai";"Chennai";"Hyderabad";"Hyderabad";"Kolkata";"Ahmedabad";"Kochi";"Delhi";"Mumbai";"Bengaluru";"Chennai";"Hyderabad";"Delhi";"Mumbai";"Bengaluru";"Kolkata";"Ahmedabad";"Kochi";"Delhi";"Mumbai";"Bengaluru";"Chennai";"Hyderabad";"Delhi";"Mumbai";"Bengaluru";"Kolkata";"Chennai";"Delhi";"Mumbai"], ...
    ["London";"Paris";"Amsterdam";"London";"Frankfurt";"Paris";"Frankfurt";"Amsterdam";"Paris";"London";"Frankfurt";"London";"Frankfurt";"London";"London";"London";"New York";"New York";"San Francisco";"Paris";"Amsterdam";"Toronto";"Toronto";"Tokyo";"Tokyo";"Paris";"Rome";"Rome";"Zurich";"Zurich";"Sydney";"Sydney";"Madrid";"Madrid";"Munich";"Munich";"Milan";"Copenhagen";"Vienna"], ...
    'VariableNames', {'Origin','Destination'});
end

function text = formatRUL(rul)
if isfinite(rul)
    text = sprintf("RUL:%.0f", rul);
else
    text = "RUL:Inf";
end
end
