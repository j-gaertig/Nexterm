const Entry = require("../models/Entry");
const Engine = require("../models/Engine");
const { resolveIdentity } = require("../utils/identityResolver");
const { getIdentityCredentials } = require("../controllers/identity");
const { createAuditLog, AUDIT_ACTIONS, RESOURCE_TYPES } = require("../controllers/audit");
const logger = require("../utils/logger");
const controlPlane = require("./controlPlane/ControlPlaneServer");

const HOOK_TIMEOUT_MS = 30000;
const HOOK_ORDER_REMOTE_FIRST = "remote-first";
const HOOK_DETAIL_MAX = 500;
const HOOK_COMMAND_LOG_MAX = 200;

const isHookEnabled = (command) => typeof command === "string" && command.trim().length > 0;

const normalizeOrder = (order, fallback = "local-first") => {
    if (order === HOOK_ORDER_REMOTE_FIRST) return HOOK_ORDER_REMOTE_FIRST;
    if (order === "local-first") return "local-first";
    if (order == null) return fallback;
    logger.warn("Unknown hook order, using default", { order, fallback });
    return fallback;
};

const truncate = (value, max) => {
    const text = String(value == null ? "" : value);
    return text.length > max ? `${text.substring(0, max)}...` : text;
};

const resolveEngineLabel = async (engineId) => {
    if (engineId) {
        const record = await Engine.findByPk(engineId).catch(() => null);
        if (record) return `engine "${record.name}"`;
        return `engine ${engineId} (offline)`;
    }
    const fallback = controlPlane.getDefaultEngineInfo();
    if (fallback && fallback.engineId) {
        const record = await Engine.findByPk(fallback.engineId).catch(() => null);
        if (record) return `engine "${record.name}"`;
    }
    return "default engine";
};

const getEntryProtocol = (entry) => (entry?.type === "server" ? entry.config?.protocol : entry?.type);

const resolveHookCredentials = async (identity) => {
    if (identity.isDirect) return identity.directCredentials || {};
    if (!identity.id) throw new Error("No identity available for this entry");
    return getIdentityCredentials(identity.id);
};

const writeAuditLog = async ({ accountId, entry, phase, target, command, success, exitCode, error, injected = false, truncated = false }) => {
    try {
        await createAuditLog({
            accountId,
            organizationId: entry.organizationId || null,
            action: AUDIT_ACTIONS.HOOK_EXECUTE,
            resource: RESOURCE_TYPES.ENTRY,
            resourceId: entry.id,
            details: {
                phase,
                target,
                command: truncate(command, HOOK_COMMAND_LOG_MAX),
                success,
                exitCode: exitCode == null ? null : exitCode,
                error: error ? truncate(error, HOOK_DETAIL_MAX) : null,
                injected,
                truncated: truncated === true,
            },
            ipAddress: null,
            userAgent: null,
        });
    } catch (err) {
        logger.warn("Failed to write hook audit log", { error: err.message });
    }
};

const isEngineOffline = (engineId) => {
    if (engineId) return !controlPlane.getEngineInfo(engineId);
    return !controlPlane.getDefaultEngineInfo();
};

const runEngineHook = async (entry, command, accountId, phase) => {
    const engineId = entry.config?.engineId || null;
    const label = await resolveEngineLabel(engineId);
    const phaseLabel = phase === "after" ? "After-disconnect" : "Pre-connect";
    const cmd = command.trim();
    let result;
    try {
        result = await controlPlane.hostExec(cmd, engineId, HOOK_TIMEOUT_MS);
    } catch (err) {
        const reason = isEngineOffline(engineId) ? `${label} is not connected` : err.message;
        await writeAuditLog({ accountId, entry, phase, target: "engine", command: cmd, success: false, exitCode: null, error: reason });
        throw new Error(`${phaseLabel} hook failed on ${label}: ${truncate(reason, HOOK_DETAIL_MAX)}`);
    }
    if (!result.success) {
        const reason = truncate(result.stderr?.trim() || result.errorMessage || `exit code ${result.exitCode}`, HOOK_DETAIL_MAX);
        await writeAuditLog({ accountId, entry, phase, target: "engine", command: cmd, success: false, exitCode: result.exitCode, error: reason, truncated: result.truncated });
        throw new Error(`${phaseLabel} hook failed on ${label}: ${reason}`);
    }
    await writeAuditLog({ accountId, entry, phase, target: "engine", command: cmd, success: true, exitCode: result.exitCode, error: null, truncated: result.truncated });
    logger.info("Engine hook succeeded", { entryId: entry.id, phase, engine: label });
    return result;
};

const injectRemoteHook = async (entry, dataSocket, command, accountId, phase) => {
    const cmd = command.trim();
    const phaseLabel = phase === "after" ? "After-disconnect" : "Pre-connect";
    if (/[\r\n\x00]/.test(cmd)) {
        await writeAuditLog({ accountId, entry, phase, target: "remote", command: cmd, success: false, exitCode: null, error: "command contains control characters" });
        throw new Error(`${phaseLabel} hook failed: command contains control characters`);
    }
    try {
        if (!dataSocket || dataSocket.destroyed === true || dataSocket.writable === false) throw new Error("session stream is not writable");
        dataSocket.write(`${cmd}\r`);
    } catch (err) {
        await writeAuditLog({ accountId, entry, phase, target: "remote", command: cmd, success: false, exitCode: null, error: err.message });
        throw new Error(`${phaseLabel} hook failed: ${truncate(err.message, HOOK_DETAIL_MAX)}`);
    }
    await writeAuditLog({ accountId, entry, phase, target: "remote", command: cmd, success: true, exitCode: null, error: null, injected: true });
    logger.info("Remote hook injected", { entryId: entry.id, phase });
};

const runRemoteOneShotHook = async (entry, accountId, identityId, directIdentity, command) => {
    const cmd = command.trim();
    if (/[\r\n\x00]/.test(cmd)) throw new Error("After-disconnect hook failed: command contains control characters");
    const result = await resolveIdentity(entry, identityId, directIdentity, accountId);
    const identity = result?.identity !== undefined ? result.identity : result;
    if (result?.accessDenied) throw new Error("You don't have access to this identity");
    if (!identity || (!identity.id && !identity.isDirect)) throw new Error("No identity available for this entry");
    const credentials = await resolveHookCredentials(identity);
    const { buildSSHParams, resolveJumpHosts } = require("./ConnectionService");
    const params = buildSSHParams(identity, credentials);
    const host = entry.config?.ip;
    const port = entry.config?.port || 22;
    if (!host) throw new Error("Missing host configuration");
    const jumpHosts = await resolveJumpHosts(entry);
    return controlPlane.execCommand(host, port, params, cmd, jumpHosts, entry.config?.engineId || null);
};

const runPreEngineHook = (entry, accountId) => {
    const command = entry.config?.preLocalCommand;
    if (!isHookEnabled(command)) return Promise.resolve(null);
    return runEngineHook(entry, command, accountId, "pre");
};

const runPreRemoteHook = (entry, dataSocket, accountId) => {
    const command = entry.config?.preRemoteCommand;
    if (!isHookEnabled(command)) return Promise.resolve(null);
    return injectRemoteHook(entry, dataSocket, command, accountId, "pre");
};

const getPreOrder = (entry) => normalizeOrder(entry.config?.preOrder, "local-first");

const getAfterOrder = (entry) => normalizeOrder(entry.config?.afterOrder, HOOK_ORDER_REMOTE_FIRST);

const runAfterHooks = async ({ entryId, accountId, identityId, directIdentity }) => {
    try {
        const entry = await Entry.findByPk(entryId);
        if (!entry || getEntryProtocol(entry) !== "ssh") return;
        const config = entry.config || {};
        const order = getAfterOrder(entry);
        const steps = order === HOOK_ORDER_REMOTE_FIRST ? ["remote", "engine"] : ["engine", "remote"];
        for (const step of steps) {
            if (step === "engine") {
                if (!isHookEnabled(config.afterLocalCommand)) continue;
                try {
                    await runEngineHook(entry, config.afterLocalCommand, accountId, "after");
                } catch (err) {
                    logger.warn("After-disconnect engine hook failed", { entryId, error: err.message });
                }
                continue;
            }
            if (!isHookEnabled(config.afterRemoteCommand)) continue;
            try {
                const result = await runRemoteOneShotHook(entry, accountId, identityId, directIdentity, config.afterRemoteCommand);
                const ok = result?.success === true;
                await writeAuditLog({
                    accountId, entry, phase: "after", target: "remote",
                    command: config.afterRemoteCommand.trim(), success: ok,
                    exitCode: result ? result.exitCode : null,
                    error: ok ? null : truncate(result?.errorMessage || result?.stderr || "remote hook failed", HOOK_DETAIL_MAX),
                });
                if (!ok) logger.warn("After-disconnect remote hook failed", { entryId });
                else logger.info("After-disconnect remote hook succeeded", { entryId });
            } catch (err) {
                logger.warn("After-disconnect remote hook failed", { entryId, error: err.message });
                await writeAuditLog({
                    accountId, entry, phase: "after", target: "remote",
                    command: config.afterRemoteCommand.trim(), success: false, exitCode: null, error: truncate(err.message, HOOK_DETAIL_MAX),
                });
            }
        }
    } catch (err) {
        logger.warn("After-disconnect hooks failed", { entryId, error: err.message });
    }
};

module.exports = {
    isHookEnabled,
    normalizeOrder,
    getEntryProtocol,
    getPreOrder,
    getAfterOrder,
    runPreEngineHook,
    runPreRemoteHook,
    runRemoteOneShotHook,
    runAfterHooks,
};
