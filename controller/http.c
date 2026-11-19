// SPDX-License-Identifier: GPL-2.0-only
/* Loopback HTTP entry point for the UVP shell orchestrator (Linux). */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { MAX_HEADERS = 16384, MAX_BODY = 16384, MAX_REPLY = 4 * 1024 * 1024,
       MAX_CLIENTS = 16, MAX_TOKEN = 512, READ_TIMEOUT = 10, API_TIMEOUT = 45 };
static const char json_type[] = "application/json; charset=utf-8";
static char token[MAX_TOKEN + 1], basic[4 * ((MAX_TOKEN + 6) / 3) + 1], ip_host[64], local_host[64];
static const char *preview_host;
static bool hardware;
static volatile sig_atomic_t stopping;

struct request {
    char *method, *path, *host, *origin, *site, *auth, *type, *length, *expect;
    size_t size;
};

static void stop(int sig) { (void)sig; stopping = 1; }

static bool write_all(int fd, const void *buf, size_t size)
{
    const char *p = buf;
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        size -= (size_t)n;
    }
    return true;
}

static const char *reason(int code)
{
    switch (code) {
    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 302: return "Found";
    case 303: return "See Other";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 408: return "Request Timeout";
    case 409: return "Conflict";
    case 413: return "Content Too Large";
    case 415: return "Unsupported Media Type";
    case 417: return "Expectation Failed";
    case 422: return "Unprocessable Content";
    case 431: return "Request Header Fields Too Large";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    default: return "Internal Server Error";
    }
}

static bool send_headers(int fd, int code, const char *type, const char *extra, size_t len)
{
    char headers[832];
    int n = snprintf(headers, sizeof(headers),
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "%sConnection: close\r\nCache-Control: no-store\r\n"
        "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        "Content-Security-Policy: default-src 'self'; script-src 'self'; "
        "style-src 'self'; img-src 'self' data:; connect-src 'self'; "
        "frame-ancestors 'none'; base-uri 'none'\r\n\r\n",
        code, reason(code), type, len, extra);
    return n > 0 && (size_t)n < sizeof(headers) && write_all(fd, headers, (size_t)n);
}

static void reply_extra(int fd, int code, const char *type, const char *extra,
                        const char *body, size_t len)
{
    if (send_headers(fd, code, type, extra, len)) write_all(fd, body, len);
}
static void reply(int fd, int code, const char *type, const char *body, size_t len)
{
    reply_extra(fd, code, type, "", body, len);
}

static void error_reply(int fd, int code, const char *message)
{
    char b[256];
    int n = snprintf(b, sizeof(b), "{\"error\":\"%s\"}\n", message);
    if (n > 0 && (size_t)n < sizeof(b)) reply(fd, code, json_type, b, (size_t)n);
}

/* Read a bounded regular file, including an anonymous file populated by api.sh. */
static char *read_file(int fd, size_t *length)
{
    struct stat st;
    *length = 0;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 ||
        st.st_size > MAX_REPLY || lseek(fd, 0, SEEK_SET) < 0) return NULL;
    size_t size = (size_t)st.st_size;
    char *buf = malloc(size + 1);
    if (!buf) return NULL;
    while (*length < size) {
        ssize_t n = read(fd, buf + *length, size - *length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { free(buf); return NULL; }
        *length += (size_t)n;
    }
    buf[size] = '\0';
    return buf;
}

static int64_t now_ms(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* Read-only inputs and replies use separate anonymous fds. A long-lived worker
 * can never keep the HTTP connection open by inheriting a response pipe. */
static int run_script(const char *script, const char *method, const char *path,
                      const char *body, size_t size, int output)
{
    int input = memfd_create("uvp-request", MFD_CLOEXEC);
    int rc = 500, status;
    if (input < 0 || output < 0 || !write_all(input, body, size) ||
        lseek(input, 0, SEEK_SET) < 0) goto out;
    pid_t parent = getpid();
    pid_t child = fork();
    if (child < 0) goto out;
    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() != parent) _exit(125);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0)
            _exit(125);
        execl(script, script, method, path, (char *)NULL);
        perror(script);
        _exit(125);
    }
    int64_t deadline = now_ms() + API_TIMEOUT * 1000;
    for (;;) {
        pid_t r = waitpid(child, &status, WNOHANG);
        if (r == child) break;
        if (r < 0 && errno != EINTR) goto out;
        if (now_ms() >= deadline) {
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            rc = 504;
            goto out;
        }
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    if (WIFEXITED(status) && !WEXITSTATUS(status)) rc = 200;
out:
    if (input >= 0) close(input);
    return rc;
}

/* The dispatch script prints a three-digit HTTP status on its first line. */
static bool status_line(int output, int *code)
{
    char data[4];
    if (lseek(output, 0, SEEK_SET) < 0 || read(output, data, sizeof(data)) != sizeof(data) ||
        data[3] != '\n' || data[0] < '2' || data[0] > '5' ||
        !isdigit((unsigned char)data[1]) || !isdigit((unsigned char)data[2])) return false;
    *code = (data[0] - '0') * 100 + (data[1] - '0') * 10 + data[2] - '0';
    return true;
}

static bool lifecycle(const char *op)
{
    struct stat st;
    int output = memfd_create("uvp-lifecycle", MFD_CLOEXEC), status = 200;
    int rc = run_script("controller/api.sh", op, NULL, "{}", 2, output);
    bool ok = rc == 200 && fstat(output, &st) == 0 &&
              (!st.st_size || (status_line(output, &status) && status < 300));
    if (!ok) fprintf(stderr, "controller/api.sh %s failed (status %d)\n", op,
                     rc == 200 ? status : rc);
    if (output >= 0) close(output);
    return ok;
}

static bool export_request(const struct request *r)
{
    if (!strcmp(r->method, "POST")) return !strcmp(r->path, "/forms/export");
    const char prefix[] = "/api/runs/";
    if (strncmp(r->path, prefix, sizeof(prefix) - 1)) return false;
    const char *id = r->path + sizeof(prefix) - 1;
    return strspn(id, "0123456789abcdef") == 12 && !strcmp(id + 12, "/export");
}

/* Use the private state filesystem for exports. They can be much larger than
 * snapshots; do not allocate their full size in the server or retain a file. */
static int export_file(void)
{
    const char *state = getenv("UVP_STATE_DIR");
    int fd = open(state, O_RDWR | O_TMPFILE | O_CLOEXEC, 0600);
    if (fd >= 0) return fd;
    char path[PATH_MAX];
    int n = snprintf(path, sizeof(path), "%s/.export-XXXXXX", state);
    if (n < 0 || (size_t)n >= sizeof(path)) return -1;
    fd = mkostemp(path, O_CLOEXEC);
    if (fd >= 0 && unlink(path)) { close(fd); return -1; }
    return fd;
}

static void copy_response(int from, int client, size_t size)
{
    char buffer[16384];
    while (size) {
        size_t chunk = size < sizeof(buffer) ? size : sizeof(buffer);
        ssize_t n = read(from, buffer, chunk);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0 || !write_all(client, buffer, (size_t)n)) break;
        size -= (size_t)n;
    }
}

static void dispatch(int fd, const struct request *r, const char *body, bool forms)
{
    struct stat st;
    int status;
    bool html = forms && !strcmp(r->path, "/forms");
    bool exporting = export_request(r);
    int output = exporting ? export_file() : memfd_create("uvp-reply", MFD_CLOEXEC);
    int rc = run_script(forms ? "controller/forms.sh" : "controller/api.sh",
                        r->method, r->path, body, r->size ? r->size : strlen(body), output);
    if (rc != 200 || fstat(output, &st) || st.st_size < 4 ||
        (uintmax_t)st.st_size > SIZE_MAX || (!exporting && st.st_size > MAX_REPLY) ||
        !status_line(output, &status)) {
        error_reply(fd, rc == 504 ? 504 : 500, "Controller request failed");
    } else if (status == 303 && html) {
        reply_extra(fd, 303, "text/html; charset=utf-8", "Location: /forms\r\n", "", 0);
    } else {
        size_t size = (size_t)st.st_size - 4;
        if (send_headers(fd, status, html ? "text/html; charset=utf-8" : json_type, "", size))
            copy_response(output, fd, size);
    }
    if (output >= 0) close(output);
}

static void serve_static(int fd, const char *path)
{
    if (hardware && !strcmp(path, "/")) {
        reply_extra(fd, 302, "text/plain; charset=utf-8", "Location: /forms\r\n", "", 0);
        return;
    }
    static const struct { const char *url, *file, *type; } assets[] = {
        {"/", "web/index.html", "text/html; charset=utf-8"},
        {"/interactive", "web/index.html", "text/html; charset=utf-8"},
        {"/index.html", "web/index.html", "text/html; charset=utf-8"},
        {"/app.js", "web/app.js", "text/javascript; charset=utf-8"},
        {"/style.css", "web/style.css", "text/css; charset=utf-8"},
        {"/forms.css", "web/forms.css", "text/css; charset=utf-8"}
    };
    for (size_t i = 0; i < sizeof(assets)/sizeof(assets[0]); ++i) {
        if (strcmp(path, assets[i].url)) continue;
        int asset = open(assets[i].file, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        size_t size = 0;
        char *buf = asset >= 0 ? read_file(asset, &size) : NULL;
        if (asset >= 0) close(asset);
        if (buf) reply(fd, 200, assets[i].type, buf, size);
        else error_reply(fd, 500, "Cannot read dashboard asset");
        free(buf);
        return;
    }
    error_reply(fd, 404, "Not found");
}

static bool constant_match(const char *candidate, const char *expected)
{
    size_t n = strlen(expected), len = strlen(candidate);
    if (len != n) return false;
    unsigned int diff = 0;
    for (size_t i = 0; i < n; ++i) diff |= (unsigned char)expected[i] ^ (unsigned char)candidate[i];
    return diff == 0;
}

static bool trusted_origin(const struct request *r)
{
    if (!r->host || (strcmp(r->host, ip_host) && strcmp(r->host, local_host) &&
        (!preview_host || strcmp(r->host, preview_host)))) return false;
    if (r->site && !strcasecmp(r->site, "cross-site")) return false;
    if (!r->origin) return true;
    if (!strncmp(r->origin, "http://", 7)) return !strcmp(r->origin + 7, r->host);
    if (!strncmp(r->origin, "https://", 8)) return !strcmp(r->origin + 8, r->host);
    return false;
}

static bool header_name_char(unsigned char c)
{
    return isalnum(c) || strchr("!#$%&'*+-.^_`|~", c);
}

static bool decimal(const char *p, unsigned long max, unsigned long *result)
{
    if (!p || !*p) return false;
    unsigned long n = 0;
    for (; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        unsigned int digit = (unsigned int)(*p - '0');
        if (n > (max - digit) / 10) return false;
        n = n * 10 + digit;
    }
    *result = n;
    return true;
}

static int parse_headers(char *buf, struct request *r)
{
    char *end = strstr(buf, "\r\n");
    if (!end) return 400;
    *end = '\0';
    r->method = buf;
    r->path = strchr(buf, ' ');
    if (!r->path) return 400;
    *r->path++ = '\0';
    char *version = strchr(r->path, ' ');
    if (!version) return 400;
    *version++ = '\0';
    if ((strcmp(version, "HTTP/1.1") && strcmp(version, "HTTP/1.0")) ||
        r->path[0] != '/' || strlen(r->path) > 2048) return 400;
    for (char *p = r->path; *p; ++p)
        if ((unsigned char)*p < 33 || (unsigned char)*p > 126) return 400;
    char *query = strchr(r->path, '?');
    if (query) *query = '\0';
    if (strcmp(r->method, "GET") && strcmp(r->method, "POST")) return 405;

    char *line = end + 2;
    while (*line) {
        end = strstr(line, "\r\n");
        if (!end) return 400;
        *end = '\0';
        char *value = strchr(line, ':');
        if (!value || value == line) return 400;
        *value++ = '\0';
        for (char *p = line; *p; ++p)
            if (!header_name_char((unsigned char)*p)) return 400;
        while (*value == ' ' || *value == '\t') ++value;
        char *last = end;
        while (last > value && (last[-1] == ' ' || last[-1] == '\t')) *--last = '\0';
        for (char *p = value; *p; ++p)
            if (((unsigned char)*p < 32 && *p != '\t') || *p == 127) return 400;
        char **slot = NULL;
        if (!strcasecmp(line, "Host")) slot = &r->host;
        else if (!strcasecmp(line, "Origin")) slot = &r->origin;
        else if (!strcasecmp(line, "Authorization")) slot = &r->auth;
        else if (!strcasecmp(line, "Sec-Fetch-Site")) slot = &r->site;
        else if (!strcasecmp(line, "Content-Length")) slot = &r->length;
        else if (!strcasecmp(line, "Content-Type")) slot = &r->type;
        else if (!strcasecmp(line, "Expect")) slot = &r->expect;
        else if (!strcasecmp(line, "Transfer-Encoding")) return 400;
        if (slot) {
            if (*slot) return 400;
            *slot = value;
        }
        line = end + 2;
    }
    if (r->length) {
        unsigned long size;
        if (!decimal(r->length, ULONG_MAX, &size)) return 400;
        if (size > MAX_BODY) return 413;
        r->size = (size_t)size;
    }
    return 0;
}

static void serve(int fd)
{
    char headers[MAX_HEADERS + 1], body[MAX_BODY + 1];
    size_t n = 0;
    int64_t deadline = now_ms() + READ_TIMEOUT * 1000;
    char *end = NULL;
    do {
        if (now_ms() >= deadline) { error_reply(fd, 408, "Request timeout"); return; }
        ssize_t k = read(fd, headers + n, MAX_HEADERS - n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return;
        n += (size_t)k;
        headers[n] = '\0';
        end = memmem(headers, n, "\r\n\r\n", 4);
        if (!end && n == MAX_HEADERS) {
            error_reply(fd, 431, "Request headers too large"); return;
        }
    } while (!end);
    size_t head_len = (size_t)(end - headers) + 4;
    if (memchr(headers, '\0', head_len)) { error_reply(fd, 400, "Invalid headers"); return; }
    size_t buffered = n - head_len;
    memcpy(body, headers + head_len, buffered);
    end[2] = '\0'; /* Keep the CRLF terminating the last header. */
    struct request r = {0};
    int rc = parse_headers(headers, &r);
    if (rc) { error_reply(fd, rc, reason(rc)); return; }
    if (!trusted_origin(&r)) { error_reply(fd, 403, "Unexpected Host or Origin"); return; }
    bool post = !strcmp(r.method, "POST");
    bool is_api = !strncmp(r.path, "/api/", 5);
    bool forms = !strcmp(r.path, "/forms") || (post && !strcmp(r.path, "/forms/export"));
    bool info = !post && !strcmp(r.path, "/api/info");
    if ((post || is_api || forms) && !info) {
        bool auth = r.auth && !strncmp(r.auth, "Bearer ", 7) && constant_match(r.auth + 7, token);
        if (!auth && forms && r.auth && !strncasecmp(r.auth, "Basic ", 6))
            auth = constant_match(r.auth + 6, basic);
        if (!auth) {
            if (forms) {
                const char message[] = "Use username uvp and the access token printed by the server.\n";
                reply_extra(fd, 401, "text/plain; charset=utf-8", "WWW-Authenticate: Basic realm=\"UVP\"\r\n",
                            message, sizeof(message) - 1);
            } else error_reply(fd, 401, "Enter the access token printed by the server");
            return;
        }
    }
    if (!post) {
        if (r.size) { error_reply(fd, 400, "GET does not accept a body"); return; }
        if (info) {
            const char *data = hardware ? "{\"mode\":\"hardware\"}" : "{\"mode\":\"demo\"}";
            reply(fd, 200, json_type, data, strlen(data));
        } else if (is_api || forms) dispatch(fd, &r, forms ? "" : "{}", forms);
        else serve_static(fd, r.path);
        return;
    }
    if (r.type) {
        char *sep = strchr(r.type, ';');
        if (sep) *sep = '\0';
    }
    if (forms && (!r.origin || strncmp(r.origin, "http://", 7) || strcmp(r.origin + 7, r.host))) {
        error_reply(fd, 403, "Form submission requires the dashboard Origin"); return;
    }
    const char *required_type = forms ? "application/x-www-form-urlencoded" : "application/json";
    if (!r.type || strcasecmp(r.type, required_type)) {
        error_reply(fd, 415, forms ? "Expected URL-encoded form" : "Use application/json"); return;
    }
    if (!r.size) { error_reply(fd, 413, "Request body too large or missing"); return; }
    if (!is_api && !forms) { error_reply(fd, 404, "Not found"); return; }
    if (r.expect) {
        if (strcasecmp(r.expect, "100-continue")) {
            error_reply(fd, 417, "Unsupported expectation"); return;
        }
        static const char acknowledged[] = "HTTP/1.1 100 Continue\r\n\r\n";
        if (!write_all(fd, acknowledged, sizeof(acknowledged) - 1)) return;
    }
    while (buffered < r.size) {
        if (now_ms() >= deadline) { error_reply(fd, 408, "Request timeout"); return; }
        ssize_t k = read(fd, body + buffered, r.size - buffered);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) { error_reply(fd, 400, "Incomplete request body"); return; }
        buffered += (size_t)k;
    }
    if (memchr(body, '\0', r.size)) { error_reply(fd, 400, "Invalid JSON"); return; }
    dispatch(fd, &r, body, forms);
}

/* Create missing state directories with private permissions. Existing parent
 * directories may be shared (for example /tmp); the final one must be owned. */
static bool state_dir(const char *path, char out[PATH_MAX])
{
    char tmp[PATH_MAX];
    size_t len = strlen(path);
    if (!len || len >= sizeof(tmp)) { errno = EINVAL; return false; }
    memcpy(tmp, path, len + 1);
    while (len > 1 && tmp[len - 1] == '/') tmp[--len] = '\0';
    for (char *p = tmp + 1;; ++p) {
        if (*p && *p != '/') continue;
        bool last = !*p;
        *p = '\0';
        if (mkdir(tmp, 0700) && errno != EEXIST) return false;
        if (last) break;
        *p = '/';
    }
    struct stat st;
    if (lstat(tmp, &st) || !realpath(tmp, out)) return false;
    if (!S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0022)) {
        errno = EACCES;
        return false;
    }
    return true;
}

static void encode_basic_credentials(void)
{
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    unsigned char input[MAX_TOKEN + 5];
    size_t n = strlen(token) + 4, j = 0;
    memcpy(input, "uvp:", 4);
    memcpy(input + 4, token, n - 4);
    for (size_t i = 0; i < n; i += 3) {
        uint32_t bits = (uint32_t)input[i] << 16;
        if (i + 1 < n) bits |= (uint32_t)input[i + 1] << 8;
        if (i + 2 < n) bits |= input[i + 2];
        basic[j++] = alphabet[(bits >> 18) & 63];
        basic[j++] = alphabet[(bits >> 12) & 63];
        basic[j++] = i + 1 < n ? alphabet[(bits >> 6) & 63] : '=';
        basic[j++] = i + 2 < n ? alphabet[bits & 63] : '=';
    }
    basic[j] = 0;
}

/* Call separately for the public worker generation and the secret access token. */
static bool random_hex(char out[65])
{
    static const char hex[] = "0123456789abcdef";
    unsigned char random[32];
    size_t pos = 0;
    while (pos < sizeof(random)) {
        ssize_t n = getrandom(random + pos, sizeof(random) - pos, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        pos += (size_t)n;
    }
    for (size_t i = 0; i < sizeof(random); i++) {
        out[2*i] = hex[random[i] >> 4];
        out[2*i + 1] = hex[random[i] & 15];
    }
    out[64] = '\0';
    return true;
}

static bool setup_token(void)
{
    const char *provided = getenv("UVP_TOKEN");
    if (provided && *provided) {
        size_t n = strlen(provided);
        if (n > MAX_TOKEN || (hardware && n < 24)) return false;
        for (size_t i = 0; i < n; i++)
            if ((unsigned char)provided[i] < 33 || (unsigned char)provided[i] > 126) return false;
        memcpy(token, provided, n + 1);
    } else if (hardware) {
        if (!random_hex(token)) return false;
    } else strcpy(token, "uvp-demo");
    encode_basic_credentials();
    return unsetenv("UVP_TOKEN") == 0;
}

static int listener(unsigned long port)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { perror("socket"); return -1; }
    int one = 1;
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) ||
        bind(fd, (struct sockaddr *)&addr, sizeof(addr))) {
        perror("bind"); close(fd); return -1;
    }
    socklen_t size = sizeof(addr);
    if (listen(fd, 32) || getsockname(fd, (struct sockaddr *)&addr, &size)) {
        perror("listen"); close(fd); return -1;
    }
    snprintf(ip_host, sizeof(ip_host), "127.0.0.1:%u", ntohs(addr.sin_port));
    snprintf(local_host, sizeof(local_host), "localhost:%u", ntohs(addr.sin_port));
    return fd;
}

static void handle_connections(int fd, int lock)
{
    pid_t children[MAX_CLIENTS] = {0};
    while (!stopping) {
        int slot = -1;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (children[i] && waitpid(children[i], NULL, WNOHANG) == children[i]) children[i] = 0;
            if (!children[i]) slot = i;
        }
        struct pollfd server = {.fd = fd, .events = POLLIN};
        if (poll(&server, 1, 250) <= 0) continue;
        int client = accept4(fd, NULL, NULL, SOCK_CLOEXEC);
        if (client < 0) { if (errno != EINTR) perror("accept"); continue; }
        struct timeval timeout = {.tv_sec = READ_TIMEOUT};
        if (setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))) {
            close(client); continue;
        }
        if (slot < 0) { error_reply(client, 503, "Server busy"); close(client); continue; }
        pid_t parent = getpid();
        pid_t child = fork();
        if (child == 0) {
            signal(SIGTERM, SIG_DFL);
            signal(SIGINT, SIG_DFL);
            if (prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() != parent) _exit(1);
            close(fd);
            close(lock);
            alarm(API_TIMEOUT + 2 * READ_TIMEOUT + 5);
            serve(client);
            close(client);
            _exit(0);
        }
        if (child > 0) children[slot] = child;
        else error_reply(client, 503, "Server busy");
        close(client);
    }
    for (int i = 0; i < MAX_CLIENTS; ++i)
        if (children[i]) kill(children[i], SIGTERM);
    for (int i = 0; i < MAX_CLIENTS; ++i)
        if (children[i])
            while (waitpid(children[i], NULL, 0) < 0 && errno == EINTR) {}
}

static void usage(FILE *out)
{
    fprintf(out, "Usage: uvp-controller [--root DIR] [--config FILE] [--data-dir DIR]\n"
                 "       [--port PORT] [--hardware] [--demo-preview-host HOST]\n"
                 "Hardware opens the shell-rendered /forms dashboard; /interactive opens the JS UI.\n");
}

int main(int argc, char **argv)
{
    const char *project = getenv("UVP_ROOT"), *conf = NULL, *data = getenv("UVP_STATE_DIR");
    unsigned long port = 8000;
    static const struct option options[] = {
        {"root",required_argument,NULL,'r'}, {"config",required_argument,NULL,'c'},
        {"data-dir",required_argument,NULL,'d'}, {"port",required_argument,NULL,'p'},
        {"hardware",no_argument,NULL,'H'}, {"demo-preview-host",required_argument,NULL,'P'},
        {"host",required_argument,NULL,'B'}, {"strictPort",no_argument,NULL,'S'},
        {"help",no_argument,NULL,'h'}, {NULL,0,NULL,0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "", options, NULL)) != -1) {
        switch (opt) {
        case 'r': project = optarg; break;
        case 'c': conf = optarg; break;
        case 'd': data = optarg; break;
        case 'p': if (!decimal(optarg, 65535, &port)) { usage(stderr); return 2; } break;
        case 'H': hardware = true; break;
        case 'P': preview_host = optarg; break;
        case 'B': if (strcmp(optarg, "127.0.0.1")) { usage(stderr); return 2; } break;
        case 'S': break;
        case 'h': usage(stdout); return 0;
        default: usage(stderr); return 2;
        }
    }
    if (optind != argc || (hardware && preview_host)) { usage(stderr); return 2; }
    umask(0077);
    char root[PATH_MAX], config[PATH_MAX], state[PATH_MAX];
    /* Supplied paths refer to the caller's cwd. Defaults refer to the project. */
    if (!realpath(project && *project ? project : ".", root) ||
        (conf && !realpath(conf, config)) || (data && !state_dir(data, state)) ||
        chdir(root) || (!conf && !realpath("config/demo.json", config)) ||
        (!data && !state_dir("var", state))) {
        perror("UVP project, configuration or state directory"); return 1;
    }
    char generation[65];
    if (!random_hex(generation)) { perror("getrandom"); return 1; }
    if (setenv("UVP_SESSION", generation, 1) ||
        setenv("UVP_ROOT", root, 1) || setenv("UVP_CONFIG", config, 1) ||
        setenv("UVP_STATE_DIR", state, 1) || setenv("UVP_MODE", hardware ? "hardware" : "demo", 1))
        { perror("setenv"); return 1; }
    if (!setup_token()) {
        fputs("Invalid access token. Use 24 to 512 printable non-space characters for hardware.\n", stderr);
        return 2;
    }
    int statefd = open(state, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (statefd < 0) { perror("state directory"); return 1; }
    int lock = openat(statefd, "server.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    close(statefd);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB)) {
        perror("Cannot lock UVP state directory (another controller may be running)"); return 1;
    }
    int fd = listener(port);
    if (fd < 0) return 1;
    struct sigaction sa = {.sa_handler = stop};
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    if (!lifecycle("init")) return 1;
    printf("UVP %s http://%s\nAccess token: %s\n", hardware ? "HARDWARE" : "DEMO", ip_host, token);
    fflush(stdout);
    handle_connections(fd, lock);
    close(fd);
    bool ok = lifecycle("shutdown");
    close(lock);
    return ok ? 0 : 1;
}
