function handles = launchTurbofanUiFigure(mode)
%LAUNCHTURBOFANUIFIGURE Open the turbofan diagnostics WebGL scene.
%
% Kept for compatibility with earlier scripts. The implementation now uses
% MATLAB's Chromium webwindow because uihtml does not reliably present
% WebGL-rendered Three.js content in this environment.

if nargin < 1 || strlength(string(mode)) == 0
    mode = "none";
end

rootFolder = fileparts(mfilename("fullpath"));
viewer = TurbofanDiagnosticsWindow("RootFolder", rootFolder, "Mode", mode, ...
    "Position", [80 80 1120 700]);

handles = struct("Viewer", viewer, "Window", viewer);
end
