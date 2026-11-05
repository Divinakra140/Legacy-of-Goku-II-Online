// Lobby list for Legacy of Goku II Co-op GLOBAL MULTIPLAYER (from the PokeWilds lobby list). Hosts re-announce every few seconds;
// entries that stop being announced expire. Game traffic never passes through
// here - players connect to each other. Each result names the records that
// changed (`saved`, `removed`) so the caller can keep them across restarts.
export const TTL_MS = 75000;
export const MAX_LOBBIES = 200;
export const MAX_PER_ADDRESS = 8; // Players on one mobile carrier often share an address.
export const MAX_BODY = 2048;

const text = (value, limit) => String(value ?? "").replace(/[\u0000-\u001f]/g, "").trim().slice(0, limit);
const whole = (value, low, high) => Math.min(high, Math.max(low, Math.trunc(Number(value)) || low));

async function publicId(key) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
    return [...new Uint8Array(digest)].slice(0, 8).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export class Directory {
    constructor(now = () => Date.now()) {
        this.now = now;
        this.lobbies = new Map(); // public id -> record
    }

    prune() {
        const cutoff = this.now() - TTL_MS;
        const removed = [];
        for (const [id, lobby] of this.lobbies) if (lobby.seen < cutoff) { this.lobbies.delete(id); removed.push(id); }
        return removed;
    }

    // Returns {status, body, saved?, removed}. `client` is the caller's internet address.
    async handle(method, path, bodyText, client) {
        if (path !== "/v1/lobbies") return { status: 404, body: { error: "not found" }, removed: [] };
        const removed = this.prune();
        const result = await this.respond(method, bodyText, client);
        result.removed = removed.concat(result.removed ?? []);
        return result;
    }

    async respond(method, bodyText, client) {
        if (method === "GET") {
            const lobbies = [...this.lobbies.values()].map(({ seen, client: _client, ...shown }) => shown);
            return { status: 200, body: { lobbies } };
        }
        if (method !== "POST" && method !== "DELETE") return { status: 405, body: { error: "method" } };
        if (bodyText.length > MAX_BODY) return { status: 413, body: { error: "too large" } };
        let data;
        try { data = JSON.parse(bodyText); } catch { return { status: 400, body: { error: "json" } }; }
        // Only the host knows the key; the list shows a hash of it, so nobody
        // else can replace or remove that host's lobby.
        const key = String(data?.key ?? "");
        if (!/^[0-9a-f]{32,64}$/.test(key)) return { status: 400, body: { error: "key" } };
        const id = await publicId(key);
        // Hosts leaving send POST {key, remove:true}; DELETE is kept for tools.
        if (method === "DELETE" || data.remove === true) {
            const existed = this.lobbies.delete(id);
            return { status: 200, body: { ok: true }, removed: existed ? [id] : [] };
        }
        const address = text(data.address, 45);
        if (!/^[0-9a-fA-F:.]{3,45}$/.test(address)) return { status: 400, body: { error: "address" } };
        if (!this.lobbies.has(id)) {
            if (this.lobbies.size >= MAX_LOBBIES) return { status: 503, body: { error: "full" } };
            let mine = 0;
            for (const lobby of this.lobbies.values()) if (lobby.client === client) mine++;
            if (mine >= MAX_PER_ADDRESS) return { status: 429, body: { error: "too many lobbies" } };
        }
        const max = whole(data.max, 1, 16);      // (the game takes the host + 15)
        const record = {
            id, address,
            name: text(data.name, 24) || "WORLD",
            host: text(data.host, 24) || "PLAYER",
            private: data.private === true,
            players: whole(data.players, 1, max), max,
            bots: whole(data.bots, 0, 15),      // (fighters the computer plays there: BRAWL, FRIENDLY CPUS)
            salt: text(data.salt, 64), protocol: text(data.protocol, 48), mods: text(data.mods, 64),
            seen: this.now(), client,
        };
        this.lobbies.set(id, record);
        return { status: 200, body: { ok: true, id, ttl: TTL_MS / 1000 }, saved: record };
    }
}
