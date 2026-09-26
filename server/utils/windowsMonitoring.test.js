const test = require("node:test");
const assert = require("node:assert/strict");
const {
    buildWindowsMonitoringCommand,
    isWindowsProbeResult,
    isPowerShellProbeResult,
    parseWindowsMonitoringOutput,
} = require("./windowsMonitoring");

test("builds a readable PowerShell command for the default cmd.exe shell", () => {
    const command = buildWindowsMonitoringCommand("cmd");

    assert.match(command, /^powershell\.exe -NoLogo -NoProfile -NonInteractive -Command "& \{/);
    assert.doesNotMatch(command, /EncodedCommand|FromBase64String|GzipStream/);
    assert.match(command, /Get-CimInstance Win32_OperatingSystem/);
    assert.match(command, /\[math\]::Max\(\[int64\]0, \$size - \$free\)/);
    assert.match(command, /ConvertTo-Json -Depth 6 -Compress/);
});

test("sends readable PowerShell directly when OpenSSH uses PowerShell as its shell", () => {
    const command = buildWindowsMonitoringCommand("powershell");

    assert.match(command, /^\$ErrorActionPreference = 'Stop'/);
    assert.doesNotMatch(command, /powershell\.exe|EncodedCommand|FromBase64String/);
});

test("detects Windows probe output and leaves Linux probe output unmatched", () => {
    assert.equal(isWindowsProbeResult({ success: true, stdout: "NEXTERM_WINDOWS\r\n" }), true);
    assert.equal(isWindowsProbeResult({ success: true, stdout: "" }), false);
    assert.equal(isWindowsProbeResult({ success: false, stdout: "NEXTERM_WINDOWS" }), false);
});

test("detects PowerShell shell probe output", () => {
    assert.equal(isPowerShellProbeResult({ success: true, stdout: "NEXTERM_POWERSHELL\r\n" }), true);
    assert.equal(isPowerShellProbeResult({ success: true, stdout: "" }), false);
    assert.equal(isPowerShellProbeResult({ success: false, stdout: "NEXTERM_POWERSHELL" }), false);
});

test("normalizes Windows metrics and preserves Unicode disk and adapter names", () => {
    const result = parseWindowsMonitoringOutput(JSON.stringify({
        cpuUsage: 17,
        memoryUsage: 62,
        memoryTotal: 17179869184,
        uptime: 123456,
        processes: 142,
        processList: [{ user: "MÜLLER\\jgaer", pid: 42, cpu: 2.5, mem: 0.2, command: "Überwachung" }],
        disk: [{
            name: "C:", size: 500000000000, rotational: null,
            partitions: [{ name: "C:", mountPoint: "C:\\", type: "NTFS", used: 250000000000, available: 250000000000, usagePercent: 50 }],
        }],
        osInfo: { hostname: "PC-Übung", name: "Windows 11 Home", version: "10.0 (Build 22631)", architecture: "64-bit" },
        network: [{ name: "Ethernet-Ä", ipv4: ["192.0.2.5"], ipv6: [], rxBytes: 1000, txBytes: 2000, state: "up" }],
    }));

    assert.equal(result.status, "online");
    assert.equal(result.loadAverage, null);
    assert.equal(result.osInfo.platform, "windows");
    assert.equal(result.osInfo.hostname, "PC-Übung");
    assert.equal(result.memoryTotal, 17179869184);
    assert.equal(result.disk[0].name, "C:");
    assert.equal(result.disk[0].rotational, null);
    assert.equal(result.processList[0].command, "Überwachung");
    assert.equal(result.network[0].name, "Ethernet-Ä");
});

test("uses empty or null defaults for missing Windows metrics", () => {
    const result = parseWindowsMonitoringOutput(JSON.stringify({ osInfo: {} }));

    assert.equal(result.cpuUsage, null);
    assert.equal(result.memoryUsage, null);
    assert.equal(result.memoryTotal, null);
    assert.deepEqual(result.disk, []);
    assert.deepEqual(result.network, []);
    assert.deepEqual(result.processList, []);
    assert.equal(result.osInfo.platform, "windows");
});

test("rejects malformed or non-object PowerShell output", () => {
    assert.throws(() => parseWindowsMonitoringOutput("not json"), /Invalid Windows monitoring JSON/);
    assert.throws(() => parseWindowsMonitoringOutput("[]"), /Invalid Windows monitoring payload/);
});
