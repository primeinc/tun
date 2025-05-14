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

## Using the PowerShell Module

For Windows users (or anyone with PowerShell Core), there's a convenient PowerShell module for managing tunnels.

### Installation

The SirTunnel module is automatically installed to `~/.tun/` when you run the `redeploy-extension.ps1` script. To load it, simply add this line to your PowerShell profile:

```powershell
Import-Module "$HOME/.tun/TunModule.psm1"
```

### Creating a Tunnel

Once the module is loaded, you can use the `tun` command alias:

```powershell
# Basic usage
tun api 3000               # Exposes localhost:3000 as https://api.tun.<your-domain>

# With custom local host (not localhost)
tun api 3000 192.168.1.10  # Exposes 192.168.1.10:3000 as https://api.tun.<your-domain>

# Force override SSH host keys (useful after VM redeployment)
tun api 3000 -Force
```

### Persistent State Management

The tunnel tool maintains persistent state across PowerShell sessions. When you create a tunnel, its details are automatically saved to `~/.tun/last.json`. This means:

1. You don't need to rely on environment variables anymore
2. The tunnel command will work reliably across terminal sessions and reboots

### Viewing Tunnel Information

To see information about the active tunnel:

```powershell
tun-ls
```

### Running Diagnostics

To run diagnostics on the tunnel VM:

```powershell
tun-diag
```

### After VM Redeployment

If you redeploy your Azure VM, the tunnel state will automatically be updated when you run the `redeploy-extension.ps1` script.

### Persistent State Management

The tunnel tool now maintains persistent state across PowerShell sessions. When you create a tunnel, its details are automatically saved to `~/.tun/last.json`. This means:

1. You don't need to rely on environment variables like `$env:LAST_TUNNEL_VM` anymore
2. The tunnel command will work reliably across terminal sessions and reboots
3. Host key verification is now handled automatically
4. Secure permissions are applied automatically when possible
5. You can easily view your current tunnel state

### Viewing Tunnel Information

To see information about the active tunnel:

```powershell
ls-tun
```

This will display details such as:
- The tunnel URL
- Local port and host
- Remote VM IP and port
- When the tunnel was created

### Running Diagnostics

If you encounter issues, you can run diagnostics on the tunnel VM:

```powershell
tun diag
```

This will show:
- Extension installation logs
- Server status
- Uptime information

### After VM Redeployment

If you redeploy your Azure VM, your tunnel state will automatically be updated. You can continue using the `tun` command without manually setting any environment variables.

## Deployment and Setup Options

### Dry Run Deployment

If you want to set up the local module files without actually deploying to Azure or modifying an existing deployment, you can use the `-DryRun` parameter:

```powershell
# Set up local files without modifying Azure resources
.\scripts\redeploy-extension.ps1 -DryRun
```

You can also specify a specific IP address to use with the `-IpOverride` parameter:

```powershell
# Set up local files using a specific IP address
.\scripts\redeploy-extension.ps1 -DryRun -IpOverride "20.30.40.50"
```

For persistent configuration, add the IP override to your config.ps1:

```powershell
# In config.ps1
$VM_IP_OVERRIDE = "20.30.40.50"
```

The script will intelligently find the best IP to use in this priority order:
1. `-IpOverride` parameter (if provided)
2. `$VM_IP_OVERRIDE` from config.ps1 (if defined)
3. Existing tunnel info from last.json (if available)
4. VM name as a last resort placeholder

This is useful for:
- Local development and testing
- Setting up the SirTunnel module when you already know the VM IP
- Environments with limited Azure privileges
- Testing module functionality before actual deployment
- Non-admin (standard user) installations where setting secure ACL permissions may fail

The `-DryRun` mode will:
1. Skip all Azure operations (no CustomScript extension deployment)
2. Set up all local files and PowerShell module components
3. Use existing or override IP values rather than placeholder values
4. Skip secure permission settings that would require administrator access

### Force Redeployment

If you want to force redeployment of the SirTunnel infrastructure, you can use the `-Force` parameter:

```powershell
# Force redeployment of the infrastructure
.\scripts\redeploy-extension.ps1 -Force
```

This ensures that all resources are recreated and any existing configurations are overridden. The `-Force` parameter is also useful when:

- The CustomScript extension is in a failed state
- You need to reset SSH host key verification after VM changes
- Establishing tunnels fails with host key verification errors

When using `-Force` with the `tun` command, it will:
1. Remove any existing SSH host keys for the VM IP address
2. Disable strict host key checking for the connection
3. Automatically accept and store the new host key

Example:

```powershell
# Force tunnel creation with new host key acceptance
tun api 3000 -Force
```

## Host Key Security

SirTunnel now includes improved host key management:

1. **Automatic Detection**: When a VM's host key changes (common after redeployment), it is detected automatically
2. **Clear Error Messages**: When host key verification fails, clear instructions are provided
3. **Key Cleanup**: The `-Force` parameter completely cleans up old keys including IP-based entries
4. **Non-Interactive Mode**: Using `-Force` enables StrictHostKeyChecking=no for easier automation

These improvements prevent the common "Host key verification failed" errors and make the tool more robust when working with dynamic cloud resources.

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
