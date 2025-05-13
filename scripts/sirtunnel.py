#!/usr/bin/env python3

import sys
import json
import signal
from urllib import request

def create_tunnel(host, port):
    """Create a tunnel from host to the specified port"""
    tunnel_id = f"{host}-{port}"
    route = {
        "@id": tunnel_id,
        "match": [{"host": [host]}],
        "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": f":{port}"}]}]
    }
    
    req = request.Request(
        method='POST',
        url='http://127.0.0.1:2019/config/apps/http/servers/sirtunnel/routes',
        headers={'Content-Type': 'application/json'},
        data=json.dumps(route).encode('utf-8')
    )
    request.urlopen(req)
    return tunnel_id

def delete_tunnel(tunnel_id):
    """Remove the tunnel with the given ID"""
    req = request.Request(
        method='DELETE',
        url=f'http://127.0.0.1:2019/id/{tunnel_id}'
    )
    request.urlopen(req)

def signal_handler(sig, frame):
    """Handle interrupt signal"""
    print("\nCleaning up tunnel")
    delete_tunnel(tunnel_id)
    sys.exit(0)

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <hostname> <port>")
        sys.exit(1)
        
    host, port = sys.argv[1], sys.argv[2]
    tunnel_id = create_tunnel(host, port)
    print(f"Tunnel created successfully: https://{host} → localhost:{port}")
    
    # Set up signal handler for clean exit
    signal.signal(signal.SIGINT, signal_handler)
    
    # Keep script running until interrupted
    print("Press Ctrl+C to stop the tunnel")
    signal.pause()  # More efficient than a while loop with sleep
