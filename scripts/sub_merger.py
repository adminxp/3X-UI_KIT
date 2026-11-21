import http.server
import socketserver
import urllib.request
import urllib.error
import urllib.parse
import base64
import sqlite3
import json
import ipaddress
import itertools
import ssl

PORT = 8899
KIT_SUB_URL = "http://127.0.0.1:10460"
KIT_SUB_CONFIG = "/etc/kit-sub/config.json"
DB_PATH = "/etc/x-ui/x-ui.db"
FALLBACK_DOMAIN = "userteleport.xcloud.ar"

HOP_BY_HOP = {
    "host", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "accept-encoding", "content-length"
}


def load_panel_sub_config():
    try:
        with open(KIT_SUB_CONFIG, encoding="utf-8") as f:
            conf = json.load(f)
        return conf["upstream"].rstrip("/"), "/" + conf["path"].strip("/") + "/"
    except Exception:
        return None, None


def fetch_direct_panel_sub(sub_id, fwd_headers):
    """Запасной прямой запрос в lucx-ui с сохранением HWID-заголовков, если kit-sub вернул 404."""
    upstream_base, panel_path = load_panel_sub_config()
    if not upstream_base or not panel_path:
        return None
    url = f"{upstream_base}{panel_path}{sub_id}"
    req = urllib.request.Request(url, headers=fwd_headers)
    ctx = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
            return resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers
    except Exception:
        return None


def build_amneziawg_uris(sub_id, domain):
    """Читает инбаунды protocol='amneziawg' из SQLite и собирает URI вида amneziawg://...#remark."""
    uris = []
    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=3)
        rows = conn.execute(
            "SELECT remark, port, settings FROM inbounds WHERE protocol = 'amneziawg' AND enable = 1"
        ).fetchall()
        conn.close()
    except Exception:
        return uris

    for remark, port, raw_settings in rows:
        try:
            settings = json.loads(raw_settings)
            srv = settings.get("server", {})
            clients = settings.get("clients", [])
        except Exception:
            continue

        base_net = None
        try:
            sub_ip = srv.get("subnetIp", "10.8.1.0")
            sub_cidr = srv.get("subnetCidr", 24)
            base_net = ipaddress.ip_network(f"{sub_ip}/{sub_cidr}", strict=False)
        except Exception:
            pass

        for idx, cl in enumerate(clients):
            if cl.get("subId") != sub_id or not cl.get("enable", True):
                continue

            client_addr = ""
            allowed = cl.get("allowedIPs")
            if isinstance(allowed, list) and allowed:
                client_addr = ", ".join(allowed)
            elif isinstance(allowed, str) and allowed.strip():
                client_addr = allowed.strip()
            elif base_net:
                host_ip = next(itertools.islice(base_net.hosts(), idx + 1, idx + 2), None)
                if host_ip:
                    client_addr = f"{host_ip}/32"

            if not client_addr:
                client_addr = f"10.8.1.{idx + 2}/32"

            dns_list = [d for d in (srv.get("primaryDns"), srv.get("secondaryDns")) if d]
            dns_str = ",".join(dns_list) if dns_list else "8.8.8.8,8.8.4.4"

            params = {
                "address": client_addr,
                "dns": dns_str,
                "mtu": str(srv.get("mtu", 1400)),
                "publickey": srv.get("publicKey", ""),
            }

            if cl.get("preSharedKey"):
                params["presharedkey"] = cl.get("preSharedKey")

            keepalive = cl.get("keepAlive") or "15-25"
            params["keepalive"] = str(keepalive)

            opt_keys = (
                "jc", "jmin", "jmax",
                "s1", "s2", "s3", "s4",
                "h1", "h2", "h3", "h4",
                "i1", "i2", "i3", "i4", "i5",
                "headerProtectionKey",
                "contentPaddingAddition",
                "rekeyAfterTime",
                "rekeyTimeout",
                "rejectAfterTime",
                "keepaliveTimeout",
                "maxHandshakeAttempts",
            )
            for k in opt_keys:
                val = srv.get(k)
                if val is not None and str(val).strip() != "":
                    params[k.lower()] = str(val).strip()

            if srv.get("randomTrailers"):
                params["randomtrailers"] = "true"
            if srv.get("disableCookies"):
                params["disablecookies"] = "true"

            query_part = urllib.parse.urlencode(sorted(params.items()), quote_via=urllib.parse.quote)
            priv_encoded = urllib.parse.quote(cl.get("privateKey", ""), safe="")
            tag = urllib.parse.quote(remark or "awg-orig", safe="-_")

            uri = f"amneziawg://{priv_encoded}@{domain}:{port}?{query_part}#{tag}"
            uris.append(uri)

    return uris


class SubMergerHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def _send_bytes(self, status_code, body_bytes, headers=None, content_type=None):
        self.send_response(status_code)
        if content_type:
            self.send_header("Content-Type", content_type)
        if headers:
            for h in headers:
                hl = h.lower()
                if hl in ("content-length", "content-type", "transfer-encoding", "connection"):
                    continue
                val = headers.get(h)
                if val is not None and "\r" not in val and "\n" not in val:
                    self.send_header(h, val)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body_bytes)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path_only, _, _ = self.path.partition("?")
        clean_parts = tuple(p for p in path_only.strip("/").split("/") if p)
        it = iter(clean_parts)
        first = next(it, "")
        second = next(it, "")
        sub_id = second if second else first

        if not sub_id:
            self._send_bytes(404, b"Not Found", content_type="text/plain; charset=utf-8")
            return

        fwd_headers = {}
        for k, v in self.headers.items():
            if k.lower() not in HOP_BY_HOP and "\r" not in v and "\n" not in v:
                fwd_headers[k] = v

        host_header = self.headers.get("Host", "")
        if host_header:
            fwd_headers["Host"] = host_header

        # Гарантируем наличие реального IP клиента для проверки HWID
        client_ip = (
            self.headers.get("X-Real-IP")
            or (self.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
            or self.client_address[0]
        )
        if client_ip:
            lower_keys = {k.lower() for k in fwd_headers}
            if "x-real-ip" not in lower_keys:
                fwd_headers["X-Real-IP"] = client_ip
            if "x-forwarded-for" not in lower_keys:
                fwd_headers["X-Forwarded-For"] = client_ip

        domain, _, _ = host_header.partition(":")
        if not domain:
            domain = FALLBACK_DOMAIN

        status_code = 200
        raw_bytes = b""
        resp_headers = {}
        content_type = "text/plain; charset=utf-8"

        req_kit = urllib.request.Request(f"{KIT_SUB_URL}{self.path}", headers=fwd_headers)
        try:
            with urllib.request.urlopen(req_kit, timeout=15) as resp:
                status_code = resp.status
                raw_bytes = resp.read()
                resp_headers = resp.headers
                content_type = resp_headers.get("Content-Type", "text/plain; charset=utf-8")
        except urllib.error.HTTPError as e:
            status_code = e.code
            raw_bytes = e.read()
            resp_headers = e.headers or {}
            content_type = resp_headers.get("Content-Type", "text/plain; charset=utf-8")

            # Если kit-sub отдал 404 (например, из-за HWID или доп. параметров в URL), пробуем напрямую lucx-ui
            if status_code == 404:
                direct = fetch_direct_panel_sub(sub_id, fwd_headers)
                if direct is not None:
                    d_status, d_body, d_headers = direct
                    if d_status == 200:
                        status_code = 200
                        raw_bytes = d_body
                        resp_headers = d_headers or {}
                        content_type = resp_headers.get("Content-Type", "text/plain; charset=utf-8")
                    else:
                        self._send_bytes(d_status, d_body, headers=d_headers, content_type=content_type)
                        return
                else:
                    self._send_bytes(status_code, raw_bytes, headers=resp_headers, content_type=content_type)
                    return
            else:
                self._send_bytes(status_code, raw_bytes, headers=resp_headers, content_type=content_type)
                return
        except Exception as e:
            self._send_bytes(502, f"Error fetching KIT sub: {e}".encode("utf-8"), content_type="text/plain; charset=utf-8")
            return

        # Если браузер запрашивает красивую HTML-страницу подписки — отдаем без изменений
        if "text/html" in content_type.lower():
            self._send_bytes(200, raw_bytes, headers=resp_headers, content_type=content_type)
            return

        # Для VPN-клиентов и кнопки скачивания вклеиваем awg_orig / awg-user-space
        kit_raw = raw_bytes.decode("utf-8", errors="ignore").strip()
        extra_uris = build_amneziawg_uris(sub_id, domain)
        final_body = kit_raw

        if extra_uris:
            try:
                padded = kit_raw + "=" * (-len(kit_raw) % 4)
                decoded = base64.b64decode(padded).decode("utf-8")
                if "://" in decoded:
                    lines = [l.strip() for l in decoded.splitlines() if l.strip()]
                    for u in extra_uris:
                        if u not in lines:
                            lines.append(u)
                    merged = "\n".join(lines) + "\n"
                    final_body = base64.b64encode(merged.encode("utf-8")).decode("utf-8")
            except Exception:
                if "://" in kit_raw and not kit_raw.startswith("{"):
                    lines = [l.strip() for l in kit_raw.splitlines() if l.strip()]
                    for u in extra_uris:
                        if u not in lines:
                            lines.append(u)
                    final_body = "\n".join(lines) + "\n"

        self._send_bytes(200, final_body.encode("utf-8"), headers=resp_headers, content_type=content_type)


class ReusableThreadingTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with ReusableThreadingTCPServer(("127.0.0.1", PORT), SubMergerHandler) as httpd:
        httpd.serve_forever()
