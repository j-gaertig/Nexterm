const MAX_CLOSE_REASON_BYTES = 123;
const TRUNCATED_RESERVE_BYTES = 3;

const truncateCloseReason = (reason) => {
    const text = String(reason == null ? "" : reason);
    if (Buffer.byteLength(text) <= MAX_CLOSE_REASON_BYTES) return text;
    const limit = MAX_CLOSE_REASON_BYTES - TRUNCATED_RESERVE_BYTES;
    let result = "";
    for (const char of text) {
        if (Buffer.byteLength(result + char) > limit) break;
        result += char;
    }
    return `${result}...`;
};

const safeCloseWs = (ws, code, reason) => {
    try {
        if (!ws || ws.readyState > 1) return false;
        ws.close(code, truncateCloseReason(reason));
        return true;
    } catch {
        try {
            if (!ws || ws.readyState > 1) return false;
            ws.close(code);
            return true;
        } catch {
            return false;
        }
    }
};

module.exports = { MAX_CLOSE_REASON_BYTES, truncateCloseReason, safeCloseWs };
