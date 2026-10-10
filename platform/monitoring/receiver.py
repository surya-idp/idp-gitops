"""Where alerts end up in this lab: a web server that writes each alert to its own log.

Alertmanager posts JSON here (its normal webhook format). In production the receiver would be
a chat or paging integration; the path up to that point (rule -> Prometheus -> Alertmanager ->
webhook) is exactly the same, and it is exercised for real.

    kubectl -n monitoring logs deploy/alert-receiver
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            payload = json.loads(body)
            for alert in payload.get("alerts", []):
                print(json.dumps({
                    "status": alert.get("status"),
                    "alert": alert.get("labels", {}).get("alertname"),
                    "severity": alert.get("labels", {}).get("severity"),
                    "service": alert.get("labels", {}).get("service"),
                    "namespace": alert.get("labels", {}).get("namespace"),
                    "summary": alert.get("annotations", {}).get("summary"),
                    "startsAt": alert.get("startsAt"),
                }), flush=True)
        except ValueError:
            print(json.dumps({"error": "not JSON", "bytes": len(body)}), flush=True)
        self.send_response(200)
        self.end_headers()

    def do_GET(self) -> None:  # health probes
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args: object) -> None:  # no access log; alerts are the log
        pass


if __name__ == "__main__":
    print(json.dumps({"message": "alert receiver listening on :8080"}), flush=True)
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    sys.exit(0)
