#!/usr/bin/env python3
"""Local git HTTP server for test/git-auth.integration.sh (standard library only).

Binds 127.0.0.1 on an ephemeral port, writes the port to --port-file and logs one line per
request to --log: method, path and auth=yes|no (whether an Authorization header was sent;
the header's value is never logged).

Modes:
  backend        requires HTTP Basic auth tester:not-a-real-token-0001 (401 otherwise) and
                 serves --repo-root through `git http-backend`
  redirect       answers every request, authenticated or not, with a 302 to <target><path>
  auth-redirect  answers a request without the correct Basic credentials with 401 and each
                 request with them with a 302 to <target><path>

The credentials are made-up test data.
"""
import argparse
import base64
import http.server
import os
import subprocess
import sys

EXPECTED = "Basic " + base64.b64encode(b"tester:not-a-real-token-0001").decode("ascii")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def record(self):
        has_auth = "yes" if self.headers.get("Authorization") else "no"
        with open(self.server.log_path, "a", encoding="ascii") as log:
            log.write("%s %s auth=%s\n" % (self.command, self.path, has_auth))

    def read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            body = b""
            while True:
                size = int(self.rfile.readline().strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return body
                body += self.rfile.read(size)
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def send_plain(self, code, headers=()):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def deny(self):
        self.send_plain(401, [("WWW-Authenticate", 'Basic realm="git"')])

    def redirect(self):
        self.send_plain(302, [("Location", self.server.target + self.path)])

    def serve(self):
        self.record()
        body = self.read_body()
        authorized = self.headers.get("Authorization") == EXPECTED
        mode = self.server.mode
        if mode == "redirect":
            self.redirect()
        elif not authorized:
            self.deny()
        elif mode == "auth-redirect":
            self.redirect()
        else:
            self.backend(body)

    def backend(self, body):
        path, _, query = self.path.partition("?")
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GIT_PROJECT_ROOT": self.server.repo_root,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "REMOTE_USER": "tester",
            "REMOTE_ADDR": "127.0.0.1",
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": self.server.repo_root,
        }
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        result = subprocess.run(
            ["git", "http-backend"], input=body, env=env, capture_output=True, check=False
        )
        head, _, payload = result.stdout.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in head.decode("latin-1").split("\r\n"):
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.strip().split(" ", 1)[0])
            elif name:
                headers.append((name, value.strip()))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = serve
    do_POST = serve


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["backend", "redirect", "auth-redirect"], required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--repo-root")
    parser.add_argument("--target")
    args = parser.parse_args()
    if args.mode == "backend" and not args.repo_root:
        parser.error("--repo-root is required for backend mode")
    if args.mode != "backend" and not args.target:
        parser.error("--target is required for redirect modes")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.mode = args.mode
    server.log_path = args.log
    server.repo_root = args.repo_root
    server.target = args.target
    open(args.log, "a", encoding="ascii").close()
    tmp = args.port_file + ".tmp"
    with open(tmp, "w", encoding="ascii") as port_file:
        port_file.write(str(server.server_address[1]))
    os.replace(tmp, args.port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
