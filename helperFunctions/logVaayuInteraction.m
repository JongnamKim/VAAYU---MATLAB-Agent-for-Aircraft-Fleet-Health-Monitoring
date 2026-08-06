function logPath = logVaayuInteraction(auditRecord)
%LOGVAAYUINTERACTION Append one VAAYU audit record as JSON Lines.

arguments
    auditRecord (1,1) struct
end

rootFolder = fileparts(fileparts(mfilename('fullpath')));
logDir = fullfile(rootFolder, 'FleetAnalytics', 'vaayuAuditLogs');
if ~isfolder(logDir)
    mkdir(logDir);
end

logPath = fullfile(logDir, "vaayu_interactions_" + string(datetime('now', 'Format', 'yyyyMMdd')) + ".jsonl");
auditRecord.loggedAt = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
auditRecord.auditLogPath = logPath;

fid = fopen(logPath, 'a');
if fid < 0
    warning('VAAYU:AuditLogUnavailable', 'Could not open VAAYU audit log: %s', logPath);
    return;
end

cleanup = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', jsonencode(auditRecord));
end
