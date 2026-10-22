// log2_ztbridge - GLOBAL MULTIPLAYER for the PC and Mac builds: the same job as the Android app's Java bridge
// (LoG2ZeroTier.java), as a small program the game starts next to itself.
//   log2_ztbridge <storage dir> <game port> <control port>
// It runs an embedded ZeroTier node (libzt) on the controller-less network that only carries <game port>
// (every copy on any system lands on the same network: crossplay), and carries the game's bytes:
//   host:  ZeroTier listener on the game port -> the game's WebSocket server on 127.0.0.1:<local port>
//   guest: 127.0.0.1:<local port> -> ZeroTier connection to the host's address, game port
// The game talks to it over 127.0.0.1:<control port>, one line per command:
//   HOST <zt port> <local port> | HOSTCLOSE | CONNECT <address> <port> <local port> | CONNECTCLOSE | QUIT
// and it sends "S <state>\t<address>\t<message>" twice a second (state: starting, joining, ready, error).
// It quits by itself when the game's control connection closes.
#include <ZeroTierSockets.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#define CLOSESOCK closesocket
static bool bad(sock_t s) { return s == INVALID_SOCKET; }
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int sock_t;
#define CLOSESOCK close
#define INVALID_SOCKET (-1)
static bool bad(sock_t s) { return s < 0; }
#endif

static std::mutex ZT;      // a ZeroTier socket is never used by two threads at once
static std::atomic<int> host_gen{0}, join_gen{0};
static std::atomic<bool> ready{false};
static std::string state = "starting", address, message;
static std::mutex SM;
static uint64_t net_id = 0;

static void set_state(const std::string& s, const std::string& m = "") { std::lock_guard<std::mutex> g(SM); state = s; message = m; }
static void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
static long long now_ms() { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

// bridge.log in the storage folder: what the connections did (the game cannot see this program's output)
static std::string log_path;
static std::mutex LM;
static void blog(const std::string& m) {
    if (log_path.empty()) return;
    std::lock_guard<std::mutex> g(LM);
    FILE* f = std::fopen(log_path.c_str(), "a");
    if (!f) return;
    std::fprintf(f, "%lld %s\n", now_ms(), m.c_str());
    std::fclose(f);
}

static void on_event(void* msg) {
    zts_event_msg_t* e = static_cast<zts_event_msg_t*>(msg);
    switch (e->event_code) {
        case ZTS_EVENT_NETWORK_NOT_FOUND: set_state("error", "The multiplayer network was not found."); break;
        case ZTS_EVENT_NETWORK_ACCESS_DENIED: set_state("error", "The multiplayer network refused this device."); break;
        case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD: set_state("error", "This game version is too old for the multiplayer network."); break;
        case ZTS_EVENT_NODE_FATAL_ERROR: set_state("error", "ZeroTier identity error. Deleting the zerotier folder resets it."); break;
        default: break;
    }
}

static void bring_up(std::string storage, uint64_t id) {
    zts_init_from_storage(storage.c_str());
    zts_init_set_event_handler(&on_event);
    if (zts_node_start() != ZTS_ERR_OK) { set_state("error", "ZeroTier could not start."); return; }
    long long dl = now_ms() + 60000;
    while (now_ms() < dl && !zts_node_is_online()) sleep_ms(100);
    if (!zts_node_is_online()) { set_state("error", "Could not reach ZeroTier. Check the internet connection."); return; }
    set_state("joining");
    zts_net_join(id);
    dl = now_ms() + 90000;
    while (now_ms() < dl) {
        { std::lock_guard<std::mutex> g(SM); if (state == "error") return; }
        if (zts_net_transport_is_ready(id) == 1 && zts_addr_is_assigned(id, ZTS_AF_INET6) == 1) break;
        sleep_ms(100);
    }
    char buf[ZTS_IP_MAX_STR_LEN] = {0};
    if (zts_addr_get_str(id, ZTS_AF_INET6, buf, sizeof buf) != ZTS_ERR_OK || !buf[0]) { set_state("error", "The multiplayer network did not respond."); return; }
    { std::lock_guard<std::mutex> g(SM); address = buf; state = "ready"; message = ""; }
    blog(std::string("network ready, this device is ") + buf);
    ready = true;
}

// ---- a link: one thread owns both ends (the local game socket, the ZeroTier socket)
// zts_errno is shared by every connection: read it under the same lock as the call, or another player's "nothing yet"
// (EAGAIN) could turn into this one's "error" and close it (with two or more players, one kept dropping on a PC host)
static int zt_read(int fd, char* b, int n, int* err) { std::lock_guard<std::mutex> g(ZT); int r = zts_bsd_read(fd, b, n); *err = zts_errno; return r; }
static int zt_write(int fd, const char* b, int n, int* err) { std::lock_guard<std::mutex> g(ZT); int r = zts_bsd_write(fd, b, n); *err = zts_errno; return r; }
static void zt_close(int fd) { std::lock_guard<std::mutex> g(ZT); zts_bsd_close(fd); }

static bool write_all(int zfd, const char* b, int n) {
    long long dl = now_ms() + 20000;
    while (n > 0) {
        int err = 0;
        int w = zt_write(zfd, b, n, &err);
        if (w > 0) { b += w; n -= w; continue; }
        if (w == 0 || err == ZTS_EAGAIN) { if (now_ms() > dl) return false; sleep_ms(1); continue; }
        return false;
    }
    return true;
}

static void carry(sock_t local, int zfd, std::atomic<int>* gen, int mine) {
    int one = 1;
    setsockopt(local, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof one);
    { std::lock_guard<std::mutex> g(ZT); zts_set_no_delay(zfd, 1); zts_set_blocking(zfd, 0); }
    std::vector<char> up(4096), down(32768);
    while (gen->load() == mine) {
        bool moved = false;
        fd_set rs; FD_ZERO(&rs); FD_SET(local, &rs);
        timeval tv{0, 1000};
        int r = select(static_cast<int>(local) + 1, &rs, nullptr, nullptr, &tv);
        if (r > 0) {
            int n = recv(local, up.data(), static_cast<int>(up.size()), 0);
            if (n <= 0) break;                                   // the game closed its side
            if (!write_all(zfd, up.data(), n)) break;
            moved = true;
        }
        int rerr = 0;
        int got = zt_read(zfd, down.data(), static_cast<int>(down.size()), &rerr);
        if (got > 0) {
            int off = 0;
            while (off < got) { int s = send(local, down.data() + off, got - off, 0); if (s <= 0) { off = -1; break; } off += s; }
            if (off < 0) break;
            moved = true;
        } else if (got == 0) break;                              // the other player closed the connection
        else if (rerr != ZTS_EAGAIN) break;
        (void)moved;
    }
    CLOSESOCK(local);
    zt_close(zfd);
}

static sock_t local_connect(int port) {
    sock_t s = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(static_cast<unsigned short>(port)); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0) { CLOSESOCK(s); return INVALID_SOCKET; }
    return s;
}

static sock_t local_listen(int port) {
    sock_t s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&one), sizeof one);
    sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(static_cast<unsigned short>(port)); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0 || listen(s, 2) != 0) { CLOSESOCK(s); return INVALID_SOCKET; }
    return s;
}

// host: accept ZeroTier connections on zport, each linked to the game's server on 127.0.0.1:lport
static void host_loop(int zport, int lport, int mine) {
    while (host_gen == mine && !ready) sleep_ms(100);
    int ls;
    { std::lock_guard<std::mutex> g(ZT);
      ls = zts_bsd_socket(ZTS_AF_INET6, ZTS_SOCK_STREAM, 0);
      zts_set_reuse_addr(ls, 1);
      if (zts_bind(ls, "::", static_cast<unsigned short>(zport)) != ZTS_ERR_OK || zts_bsd_listen(ls, 8) != ZTS_ERR_OK) { zts_bsd_close(ls); ls = -1; }
      else zts_set_blocking(ls, 0); }
    if (ls < 0) { set_state("error", "Could not open the game for others."); return; }
    while (host_gen == mine) {
        char ra[ZTS_IP_MAX_STR_LEN]; unsigned short rp = 0; int c;
        { std::lock_guard<std::mutex> g(ZT); c = zts_accept(ls, ra, sizeof ra, &rp); }
        if (c < 0) { sleep_ms(50); continue; }
        blog(std::string("host: a player connected from ") + ra);
        sock_t l = local_connect(lport);
        if (bad(l)) { zt_close(c); continue; }
        std::thread(carry, l, c, &host_gen, mine).detach();
    }
    zt_close(ls);
}

// guest: the game connects to 127.0.0.1:lport, each connection linked to the host's address over ZeroTier
static void join_loop(std::string addr, int rport, int lport, int mine) {
    sock_t ls = local_listen(lport);
    if (bad(ls)) { blog("join: could not open local port " + std::to_string(lport)); return; }
    blog("join: waiting for the game on local port " + std::to_string(lport));
    while (join_gen == mine) {
        fd_set rs; FD_ZERO(&rs); FD_SET(ls, &rs);
        timeval tv{0, 200000};
        if (select(static_cast<int>(ls) + 1, &rs, nullptr, nullptr, &tv) <= 0) continue;
        sock_t l = accept(ls, nullptr, nullptr);
        if (bad(l)) continue;
        blog("join: the game connected locally");
        while (join_gen == mine && !ready) sleep_ms(100);
        int z = zts_bsd_socket(ZTS_AF_INET6, ZTS_SOCK_STREAM, 0);
        long long t0 = now_ms();
        blog("join: connecting to " + addr + " port " + std::to_string(rport));
        if (z < 0 || zts_connect(z, addr.c_str(), static_cast<unsigned short>(rport), 15000) != ZTS_ERR_OK) {
            blog("join: could not connect after " + std::to_string(now_ms() - t0) + " ms (errno " + std::to_string(zts_errno) + ")");
            if (z >= 0) zt_close(z);
            CLOSESOCK(l);
            continue;
        }
        blog("join: connected after " + std::to_string(now_ms() - t0) + " ms");
        std::thread(carry, l, z, &join_gen, mine).detach();
    }
    CLOSESOCK(ls);
}

int main(int argc, char** argv) {
    if (argc < 4) { std::fprintf(stderr, "usage: log2_ztbridge STORAGE GAMEPORT CONTROLPORT\n"); return 2; }
#ifdef _WIN32
    WSADATA wd; WSAStartup(MAKEWORD(2, 2), &wd);
#endif
    const int port = std::atoi(argv[2]), ctrl = std::atoi(argv[3]);
    log_path = std::string(argv[1]) + "/bridge.log";
    { FILE* f = std::fopen(log_path.c_str(), "w"); if (f) std::fclose(f); }      // (a new one each start)
    blog("helper started");
    net_id = 0xff00000000000000ULL | (static_cast<uint64_t>(port) << 40) | (static_cast<uint64_t>(port) << 24);
    sock_t cl = local_listen(ctrl);
    if (bad(cl)) return 3;
    sock_t game = accept(cl, nullptr, nullptr);
    CLOSESOCK(cl);
    if (bad(game)) return 4;
    std::thread(bring_up, std::string(argv[1]), net_id).detach();
    std::string line;
    long long next = 0;
    while (true) {
        if (now_ms() >= next) {
            std::string st, ad, me;
            { std::lock_guard<std::mutex> g(SM); st = state; ad = address; me = message; }
            if (ready && me.empty() && zts_net_transport_is_ready(net_id) != 1) me = "Reconnecting...";
            std::string out = "S " + st + "\t" + ad + "\t" + me + "\n";
            if (send(game, out.c_str(), static_cast<int>(out.size()), 0) <= 0) break;
            next = now_ms() + 500;
        }
        fd_set rs; FD_ZERO(&rs); FD_SET(game, &rs);
        timeval tv{0, 100000};
        int r = select(static_cast<int>(game) + 1, &rs, nullptr, nullptr, &tv);
        if (r <= 0) continue;
        char b[512];
        int n = recv(game, b, sizeof b, 0);
        if (n <= 0) break;                                       // the game is gone
        line.append(b, static_cast<size_t>(n));
        size_t nl;
        while ((nl = line.find('\n')) != std::string::npos) {
            std::string c = line.substr(0, nl); line.erase(0, nl + 1);
            blog("command: " + c);
            char a[128] = {0}; int x = 0, y = 0;
            if (std::sscanf(c.c_str(), "HOST %d %d", &x, &y) == 2) { int g = ++host_gen; std::thread(host_loop, x, y, g).detach(); }
            else if (c.rfind("HOSTCLOSE", 0) == 0) ++host_gen;
            else if (std::sscanf(c.c_str(), "CONNECT %127s %d %d", a, &x, &y) == 3) { int g = ++join_gen; std::thread(join_loop, std::string(a), x, y, g).detach(); }
            else if (c.rfind("CONNECTCLOSE", 0) == 0) ++join_gen;
            else if (c.rfind("QUIT", 0) == 0) { CLOSESOCK(game); std::_Exit(0); }
        }
    }
    std::_Exit(0);
}
