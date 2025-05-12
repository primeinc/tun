#!/usr/bin/env python3
"""
SirTunnel: A tool to dynamically configure Caddy reverse proxies via SSH tunnels

Enhanced version with improved error handling and timeout management
Based on the original by Anders Pitman: https://github.com/anderspitman/SirTunnel
"""

import sys
import os
import json
import signal
import time
import argparse
import urllib.request
import urllib.error
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("sirtunnel")

# Constants
CADDY_API_URL = "http://localhost:2019"
MAX_RETRIES = 3
RETRY_DELAY = 2  # seconds

class SirTunnel:
    def __init__(self, domain, local_port):
        self.domain = domain
        self.local_port = local_port
        self.route_id = None
        
        # Set up signal handlers
        signal.signal(signal.SIGINT, self.handle_signal)
        signal.signal(signal.SIGTERM, self.handle_signal)
        
        logger.info(f"Starting SirTunnel for {self.domain} -> localhost:{self.local_port}")
    
    def handle_signal(self, signum, frame):
        """Handle termination signals by cleaning up Caddy routes"""
        logger.info(f"Received signal {signum}. Cleaning up and exiting...")
        self.remove_route()
        sys.exit(0)
    
    def make_request(self, method, path, data=None, retries=MAX_RETRIES):
        """Make HTTP request to Caddy API with retry logic"""
        url = f"{CADDY_API_URL}{path}"
        
        headers = {"Content-Type": "application/json"}
        
        if data is not None:
            data = json.dumps(data).encode()
        
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        
        for attempt in range(retries):
            try:
                with urllib.request.urlopen(req) as response:
                    if method == "GET":
                        return json.loads(response.read().decode())
                    return True
            except urllib.error.URLError as e:
                logger.warning(f"Request failed (attempt {attempt+1}/{retries}): {e}")
                if attempt < retries - 1:
                    time.sleep(RETRY_DELAY)
                else:
                    logger.error(f"Request to {url} failed after {retries} attempts")
                    raise
        
        return False
    
    def add_route(self):
        """Add a new route to Caddy configuration"""
        route_config = {
            "@id": f"sirtunnel_{self.domain.replace('.', '_')}",
            "match": [{
                "host": [self.domain]
            }],
            "handle": [{
                "handler": "reverse_proxy",
                "upstreams": [{
                    "dial": f"localhost:{self.local_port}"
                }]
            }]
        }
        
        self.route_id = route_config["@id"]
        
        # Path to add a new route to the server
        path = "/config/apps/http/servers/srv0/routes"
        
        try:
            logger.info(f"Adding route for {self.domain} -> localhost:{self.local_port}")
            result = self.make_request("POST", path, route_config)
            logger.info("Route added successfully")
            return True
        except Exception as e:
            logger.error(f"Failed to add route: {e}")
            return False
    
    def remove_route(self):
        """Remove the route from Caddy configuration"""
        if not self.route_id:
            logger.warning("No route to remove")
            return False
        
        try:
            # First check if route exists
            path = f"/id/{self.route_id}"
            try:
                self.make_request("GET", path, retries=1)
            except:
                logger.info("Route does not exist or was already removed")
                return False
            
            # Delete the route
            logger.info(f"Removing route for {self.domain}")
            self.make_request("DELETE", path)
            logger.info("Route removed successfully")
            return True
        except Exception as e:
            logger.error(f"Failed to remove route: {e}")
            return False
    
    def run(self):
        """Main execution method"""
        # Add the route to Caddy
        if not self.add_route():
            return 1
        
        logger.info(f"Tunnel established at https://{self.domain}")
        logger.info("Press Ctrl+C to stop...")
        
        # Keep the tunnel alive until interrupted
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            logger.info("Keyboard interrupt received")
            self.remove_route()
        
        return 0

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description='SirTunnel: Caddy-based SSH tunneling')
    parser.add_argument('domain', help='Domain name for the tunnel (e.g., api.tun.example.com)')
    parser.add_argument('local_port', type=int, help='Local port on the server to forward to')
    parser.add_argument('--debug', action='store_true', help='Enable debug logging')
    return parser.parse_args()

def main():
    """Main entry point"""
    args = parse_args()
    
    # Set debug logging if requested
    if args.debug:
        logger.setLevel(logging.DEBUG)
        logger.debug("Debug logging enabled")
    
    tunnel = SirTunnel(args.domain, args.local_port)
    return tunnel.run()

if __name__ == "__main__":
    sys.exit(main())
