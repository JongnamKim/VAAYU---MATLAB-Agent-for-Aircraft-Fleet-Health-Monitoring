function animator = createVaayuNeuralSphereAnimator(ax)
%CREATEVAAYUNEURALSPHEREANIMATOR Build and update VAAYU's neural sphere.
%   The returned struct exposes update, setVisible, and delete function
%   handles. It owns only the MATLAB graphics objects for the neural sphere;
%   WebGL turbofan diagnostics are hosted separately by TurbofanDiagnosticsWindow.

[baseX, baseY, baseZ, R] = getNodesData("sphere");
N = numel(baseX);

nEdges = 100;
edgePairs = randi(N, nEdges, 2);
dists = sqrt((baseX(edgePairs(:,1))-baseX(edgePairs(:,2))).^2 + ...
             (baseY(edgePairs(:,1))-baseY(edgePairs(:,2))).^2 + ...
             (baseZ(edgePairs(:,1))-baseZ(edgePairs(:,2))).^2);
edgePairs = edgePairs(dists < 0.55, :);
nEdges = size(edgePairs, 1);

nParticles = 100;
pIdx = randi(N, 1, nParticles);
shrink = 0.15 + 0.7 * rand(1, nParticles);
pX = baseX(pIdx) .* shrink;
pY = baseY(pIdx) .* shrink;
pZ = baseZ(pIdx) .* shrink;

edgeLines = gobjects(nEdges, 1);
for i = 1:nEdges
    ex = [baseX(edgePairs(i,1)), baseX(edgePairs(i,2))];
    ey = [baseY(edgePairs(i,1)), baseY(edgePairs(i,2))];
    ez = [baseZ(edgePairs(i,1)), baseZ(edgePairs(i,2))];
    edgeLines(i) = plot3(ax, ex, ey, ez, "-", ...
        "Color", [0.1 0.4 0.9 0.35], "LineWidth", 0.6);
end

hNodes = scatter3(ax, baseX, baseY, baseZ, 8, ...
    repmat([0.3 0.7 1], N, 1), "filled", ...
    "MarkerFaceAlpha", 0.6);

hPart = scatter3(ax, pX, pY, pZ, 4, ...
    repmat([0.6 0.85 1], nParticles, 1), "filled", ...
    "MarkerFaceAlpha", 0.3);

t = 0;
currentScale = 1.0;
smoothAmp = 0;
rotAngle = 0;
pulsePhase = 0;
edgeFlash = zeros(nEdges, 1);
particleVel = 0.003 * randn(nParticles, 3);

animator = struct( ...
    "update", @update, ...
    "setVisible", @setVisible, ...
    "delete", @deleteGraphics);

    function frame = update(isSpeaking, isRecording, recObj, speakVolume)
        t = t + 0.04;
        rotAngle = rotAngle + 0.6;
        pulsePhase = pulsePhase + 0.08;

        rawAmp = 0;
        volScale = speakVolume / 100;
        if isSpeaking
            rawAmp = 0.35 + 0.30 * sin(pulsePhase * 3.7) ...
                          + 0.15 * sin(pulsePhase * 7.3) ...
                          + 0.10 * sin(pulsePhase * 13.1);
            rawAmp = max(min(rawAmp, 1.0), 0.15) * volScale;
        elseif isRecording && ~isempty(recObj) && recObj.TotalSamples > 512
            data = getaudiodata(recObj);
            seg = data(max(1, end-2205):end);
            rawAmp = min(mean(abs(seg)) * 12, 1.0);
        end
        smoothAmp = 0.72 * smoothAmp + 0.28 * rawAmp;

        breathe = 0.06 * sin(pulsePhase);
        targetScale = 1.0 + breathe + 2.8 * smoothAmp;
        currentScale = 0.75 * currentScale + 0.25 * targetScale;

        amp = smoothAmp;
        if isSpeaking
            if amp < 0.4
                nodeColor = [0.9 + 0.1*amp, 0.6 + 0.2*amp, 0.1];
                edgeColor = [0.7, 0.4, 0.05, 0.35 + 0.3*amp];
            else
                f = (amp - 0.4) / 0.6;
                nodeColor = [1.0, 0.75 + 0.25*f, 0.1 + 0.6*f];
                edgeColor = [0.9 + 0.1*f, 0.55 + 0.2*f, 0.1 + 0.3*f, 0.60 + 0.3*f];
            end
        else
            if amp < 0.3
                nodeColor = [0.2 + 0.4*amp, 0.55 + 0.3*amp, 1.0];
                edgeColor = [0.05 + 0.1*amp, 0.25 + 0.2*amp, 0.9, 0.30 + 0.3*amp];
            elseif amp < 0.7
                f = (amp - 0.3) / 0.4;
                nodeColor = [0.4 + 0.5*f, 0.7 - 0.1*f, 1.0 - 0.2*f];
                edgeColor = [0.1 + 0.5*f, 0.5 - 0.1*f, 0.9, 0.55 + 0.2*f];
            else
                f = (amp - 0.7) / 0.3;
                nodeColor = [0.9 + 0.1*f, 0.6 - 0.2*f, 0.8 + 0.2*f];
                edgeColor = [0.6 + 0.3*f, 0.4 - 0.1*f, 0.9, 0.75 + 0.2*f];
            end
        end

        th = deg2rad(rotAngle);
        Rmat = [cos(th) -sin(th) 0; sin(th) cos(th) 0; 0 0 1];
        rotated = Rmat * [baseX; baseY; baseZ];

        perturbAmp = 0.04 + 0.12 * amp;
        px = perturbAmp * sin(3*baseY + t) .* cos(2*baseZ + t*0.7);
        py = perturbAmp * cos(3*baseX + t) .* sin(2*baseZ + t*0.5);
        pz = perturbAmp * sin(2*baseX + t) .* cos(3*baseY + t*0.9);

        nx = currentScale * (rotated(1,:) + px);
        ny = currentScale * (rotated(2,:) + py);
        nz = currentScale * (rotated(3,:) + pz);

        hNodes.XData = nx;
        hNodes.YData = ny;
        hNodes.ZData = nz;
        hNodes.CData = repmat(nodeColor, N, 1);
        hNodes.SizeData = 8 + 14 * amp;
        hNodes.MarkerFaceAlpha = 0.5 + 0.4 * amp;

        newFlash = (rand(nEdges, 1) < (0.04 + 0.35 * amp));
        edgeFlash = 0.6 * edgeFlash + 0.4 * newFlash;

        for edgeIdx = 1:nEdges
            i1 = edgePairs(edgeIdx, 1);
            i2 = edgePairs(edgeIdx, 2);
            edgeLines(edgeIdx).XData = [nx(i1), nx(i2)];
            edgeLines(edgeIdx).YData = [ny(i1), ny(i2)];
            edgeLines(edgeIdx).ZData = [nz(i1), nz(i2)];
            alpha = edgeColor(4) + 0.45 * edgeFlash(edgeIdx);
            col = edgeColor(1:3) + 0.5 * edgeFlash(edgeIdx) * [0.3 0.1 0.0];
            edgeLines(edgeIdx).Color = [min(col, 1), min(alpha, 1)];
            edgeLines(edgeIdx).LineWidth = 0.5 + 1.2 * edgeFlash(edgeIdx);
        end

        pX = pX + particleVel(:,1)' * (1 + 3*amp);
        pY = pY + particleVel(:,2)' * (1 + 3*amp);
        pZ = pZ + particleVel(:,3)' * (1 + 3*amp);

        rr = sqrt(pX.^2 + pY.^2 + pZ.^2);
        out = rr > R * 0.85;
        if any(out)
            factor = (R * 0.5) ./ rr(out);
            pX(out) = pX(out) .* factor;
            pY(out) = pY(out) .* factor;
            pZ(out) = pZ(out) .* factor;
            particleVel(out,:) = -0.5 * particleVel(out,:);
        end

        rotP = Rmat * [pX; pY; pZ] * currentScale;
        hPart.XData = rotP(1,:);
        hPart.YData = rotP(2,:);
        hPart.ZData = rotP(3,:);
        hPart.CData = repmat(nodeColor * 0.75 + 0.25, nParticles, 1);
        hPart.SizeData = 3 + 8 * amp;
        hPart.MarkerFaceAlpha = 0.2 + 0.4 * amp;

        el = 20 + 6 * sin(t * 0.15);
        view(ax, rotAngle * 0.3, el);

        frame = struct( ...
            "Amplitude", amp, ...
            "ActivityLabel", activityLabel(amp));
    end

    function setVisible(tf)
        if tf
            vis = "on";
        else
            vis = "off";
        end
        set(edgeLines(isgraphics(edgeLines)), "Visible", vis);
        if isgraphics(hNodes), hNodes.Visible = vis; end
        if isgraphics(hPart), hPart.Visible = vis; end
    end

    function deleteGraphics()
        delete(edgeLines(isgraphics(edgeLines)));
        if isgraphics(hNodes), delete(hNodes); end
        if isgraphics(hPart), delete(hPart); end
    end
end

function lbl = activityLabel(a)
if a < 0.1
    lbl = "DORMANT";
elseif a < 0.3
    lbl = "LOW";
elseif a < 0.55
    lbl = "MODERATE";
elseif a < 0.75
    lbl = "HIGH";
else
    lbl = "SURGE";
end
end
