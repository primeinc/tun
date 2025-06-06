#!/usr/bin/env python3

import sys
import json
import time
import socket
from urllib import request


if __name__ == '__main__':

    host = sys.argv[1]
    port = sys.argv[2]
    tunnel_id = host + '-' + port

    # Optional: Clean up existing route if present to prevent conflicts
    check_url = f'http://127.0.0.1:2019/id/{tunnel_id}'
    try:
        resp = request.urlopen(check_url)
        # If we got a 200 OK, a route with this ID exists – delete it
        request.urlopen(request.Request(method='DELETE', url=check_url))
        print(f"[Warn] Removed existing route for {tunnel_id} before creating a new one")
    except Exception:
        pass  # 404 Not Found means no existing route

    caddy_add_route_request = {
        "@id": tunnel_id,
        "match": [{
            "host": [host],
        }],
        "handle": [{
            "handler": "reverse_proxy",
            "upstreams":[{
                "dial": '127.0.0.1:' + port  # Use explicit IPv4 loopback to avoid IPv6 issues
            }]
        }]
    }

    body = json.dumps(caddy_add_route_request).encode('utf-8')
    headers = {
        'Content-Type': 'application/json'
    }
    create_url = 'http://127.0.0.1:2019/config/apps/http/servers/sirtunnel/routes'
    req = request.Request(method='POST', url=create_url, headers=headers)
    request.urlopen(req, body)

    # Verify that the forwarded port is actually accessible
    # This ensures we fail fast if the SSH tunnel didn't bind properly
    probe = socket.socket()
    probe.settimeout(2)
    try:
        probe.connect(("127.0.0.1", int(port)))
        probe.close()
        print("Tunnel created successfully - port verified and accessible")
    except Exception as e:
        print(f"Error: Tunnel target port {port} not reachable - removing route ({str(e)})")
        delete_url = 'http://127.0.0.1:2019/id/' + tunnel_id
        request.urlopen(request.Request(method='DELETE', url=delete_url))
        sys.exit(1)

    while True:
        try:
            time.sleep(1)
        except KeyboardInterrupt:

            print("Cleaning up tunnel")
            delete_url = 'http://127.0.0.1:2019/id/' + tunnel_id
            req = request.Request(method='DELETE', url=delete_url)
            request.urlopen(req)
            break