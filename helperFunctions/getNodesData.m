function [baseX, baseY, baseZ, R] = getNodesData(shape)
arguments
    shape (1,1) string {mustBeMember(shape, ["sphere", "membrane"])} = "membrane"
end

R = 0.8;

switch shape
    case "sphere"
        N   = 300;
        phi   = acos(1 - 2*(1:N)/N);
        theta = pi*(1 + sqrt(5))*(1:N);

        baseX = R * sin(phi) .* cos(theta);
        baseY = R * sin(phi) .* sin(theta);
        baseZ = R * cos(phi);

    case "membrane"
        L = 16 * membrane(1, 10);
        [nRows, nCols] = size(L);
        [Xg, Yg] = meshgrid(1:nCols, 1:nRows);

        xAll = Xg(:);  yAll = Yg(:);  zAll = L(:);
        valid = ~isnan(zAll);
        nodes = [xAll(valid), yAll(valid), zAll(valid)];

        nodes  = nodes - mean(nodes, 1);
        nodes  = nodes * (R / max(vecnorm(nodes, 2, 2)));

        baseX = nodes(:,1)';
        baseY = nodes(:,2)';
        baseZ = nodes(:,3)';
end
end
