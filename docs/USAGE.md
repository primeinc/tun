# SirTunnel Usage Guide

Once the SirTunnel infrastructure is deployed and running, you can use it to establish secure tunnels from your local machine to the internet.

## Basic Usage

The general pattern for using SirTunnel is:

```bash
ssh -t -R <REMOTE_PORT>:<LOCAL_HOST>:<LOCAL_PORT> <VM_USER>@<VM_PUBLIC_IP> sirtunnel.py <SUBDOMAIN>.tun.title.dev <REMOTE_PORT>
```

### Parameters Explained

- `-t`: Allocates a pseudo-terminal. This ensures that pressing Ctrl+C locally correctly terminates the sirtunnel.py script on the remote server.
- `-R <REMOTE_PORT>:<LOCAL_HOST>:<LOCAL_PORT>`: Sets up SSH remote port forwarding. Traffic to the <REMOTE_PORT> on the VM will be forwarded to <LOCAL_HOST>:<LOCAL_PORT> on your local machine.
- `<VM_USER>@<VM_PUBLIC_IP>`: SSH credentials for connecting to the Azure VM.
- `sirtunnel.py <SUBDOMAIN>.tun.title.dev <REMOTE_PORT>`: The command executed on the remote VM that configures Caddy to route traffic.

## Common Examples

### Exposing a Local Web Development Server

```bash
# Expose localhost:3000 via https://app.tun.title.dev
ssh -t -R 9001:localhost:3000 azureuser@<VM_PUBLIC_IP> sirtunnel.py app.tun.title.dev 9001
```

### Exposing a Local API Server

```bash
# Expose localhost:8080 via https://api.tun.title.dev
ssh -t -R 9002:localhost:8080 azureuser@<VM_PUBLIC_IP> sirtunnel.py api.tun.title.dev 9002
```

### Exposing a Service on Another Local Machine

```bash
# Expose 192.168.1.100:8000 via https://internal.tun.title.dev
ssh -t -R 9003:192.168.1.100:8000 azureuser@<VM_PUBLIC_IP> sirtunnel.py internal.tun.title.dev 9003
```

## Managing Tunnels

### Starting a Tunnel

Run any of the example commands above to start a tunnel. The connection will remain active as long as the SSH session is maintained.

### Stopping a Tunnel

Press `Ctrl+C` in the terminal where the SSH command is running. This will:

1. Send an interrupt signal to the sirtunnel.py process on the VM
2. The script will remove the route from Caddy's configuration
3. The SSH connection will close

### Tunnel Lifecycle

When a tunnel is created:

1. The sirtunnel.py script adds a route to Caddy's configuration via the Admin API
2. Caddy automatically obtains a TLS certificate if needed
3. External traffic to https://<SUBDOMAIN>.tun.title.dev is now routed through Caddy, through the SSH tunnel, to your local service

When a tunnel is stopped:

1. The sirtunnel.py script removes the route from Caddy's configuration
2. Traffic to the subdomain is no longer routed (returns a Caddy error page)

## Best Practices

- Use unique REMOTE_PORT numbers for each tunnel to avoid conflicts
- Choose descriptive subdomain names for your services
- Remember that the tunnel is only active while the SSH connection is maintained
- For long-running tunnels, consider using a terminal multiplexer like tmux or screen
- Monitor Caddy logs on the VM for debugging: `sudo journalctl -u caddy --no-pager`

## Troubleshooting

If you encounter issues, please see [Troubleshooting](TROUBLESHOOTING.md) for common solutions.
