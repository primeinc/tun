# MX SMTP Sink Server

This document describes the temporary MX (SMTP) server functionality that dumps incoming emails to the console for testing purposes.

## Overview

The SMTP sink server is a lightweight Python-based mail server that:
- Listens on port 25 for incoming SMTP connections
- Accepts all incoming emails without authentication
- Displays email content to the console/logs
- Runs as a systemd service on the VM
- **Port 25 is only open when a tunnel is active** (security feature)

## Components

### 1. SMTP Sink Script (`scripts/smtp_sink.py`)
A Python script using `aiosmtpd` that:
- Binds to 0.0.0.0:25 to accept connections from any source
- Implements a simple handler that prints email details
- Returns standard SMTP responses

### 2. System Service (`smtpsink.service`)
A systemd service that:
- Runs the SMTP sink script automatically on VM startup
- Restarts on failure for reliability
- Logs output to journald for monitoring

### 3. Network Security
- Port 25 is opened in the Azure NSG (Network Security Group)
- No authentication required (suitable for testing only)
- Should be disabled or secured for production use

## Setup

The SMTP sink is automatically set up during VM deployment:

1. **Python Dependencies**: The `install.sh` script installs Python 3, pip, and the `aiosmtpd` package
2. **Service Configuration**: A systemd service is created and enabled
3. **Firewall Rules**: Port 25 is dynamically managed - only open when a tunnel is active

## Usage

### Automatic Email Display in Tunnel Console

When you create a tunnel, emails are automatically displayed in the same console:

```bash
# Create tunnel - emails will appear here automatically
tun api 3000

# Example output:
# Tunnel created successfully - port verified and accessible
# Opening port 25 for SMTP traffic...
# [SMTP] === NEW EMAIL ===
# [SMTP] From: sender@example.com
# [SMTP] To: ['anything@api.tun.yourdomain.com']
# [SMTP] Subject: Test Email
```

Port 25 is only open while the tunnel is active and closes automatically when you stop the tunnel (Ctrl+C).

### Manual Log Viewing

You can also SSH into the VM and monitor the SMTP sink logs directly:

```bash
# View real-time logs
sudo journalctl -u smtpsink.service -f

# View last 50 log entries
sudo journalctl -u smtpsink.service -n 50

# View logs from the last hour
sudo journalctl -u smtpsink.service --since "1 hour ago"
```

### Service Management

```bash
# Check service status
sudo systemctl status smtpsink.service

# Stop the service
sudo systemctl stop smtpsink.service

# Start the service
sudo systemctl start smtpsink.service

# Restart the service
sudo systemctl restart smtpsink.service

# Disable the service (won't start on boot)
sudo systemctl disable smtpsink.service
```

### Testing the SMTP Server

From any external machine, you can test the SMTP server:

```bash
# Using telnet
telnet <VM_PUBLIC_IP> 25

# Using swaks (SMTP test tool)
swaks --to test@yourdomain.com --server <VM_PUBLIC_IP>

# Using Python
python3 -c "
import smtplib
server = smtplib.SMTP('<VM_PUBLIC_IP>', 25)
server.sendmail('sender@test.com', ['recipient@test.com'], 'Subject: Test\n\nTest message')
server.quit()
"
```

### Configuring MX Records

To receive emails for a domain:

1. Create an MX record in your DNS zone:
   - Name: `mx-test` (or subdomain of your choice)
   - Type: `MX`
   - Priority: `10`
   - Value: `<VM_PUBLIC_IP>` or `sirtunnel-vm.yourdomain.com`

2. Wait for DNS propagation (usually 5-15 minutes)

3. Test by sending an email to `anything@mx-test.yourdomain.com`

## Security Considerations

⚠️ **CRITICAL WARNING**: This SMTP sink is for testing only and should NEVER be used in production!

### Security Issues:
- **No authentication**: Accepts mail from any source without verification
- **No encryption**: All communication is in plain text (no TLS/SSL)
- **Open relay risk**: Could be abused for spam if exposed to internet
- **Resource exhaustion**: Limited protection against DoS attacks (1MB message limit, basic resource quotas)
- **Sensitive data exposure**: All email content is logged in plain text
- **Wide network access**: Binds to all interfaces (0.0.0.0)

### Security Mitigations Applied:
- **Systemd hardening**: ProtectSystem, PrivateTmp, NoNewPrivileges
- **Resource limits**: 512MB memory limit, 50% CPU quota, 1MB message size limit
- **Signal handling**: Proper shutdown on SIGTERM/SIGINT
- **Error handling**: Won't crash on malformed emails
- **Logging framework**: Structured logging instead of raw prints

### Still Missing:
- Non-root user (currently runs as root with CAP_NET_BIND_SERVICE)
- IP allowlisting/blocklisting
- Rate limiting per connection
- TLS support
- Authentication mechanisms
- Proper log rotation

For production use, consider:
- Implementing proper authentication
- Enabling TLS/SSL
- Restricting source IPs
- Adding rate limiting
- Implementing proper mail handling

## Troubleshooting

### Service Won't Start
```bash
# Check for port conflicts
sudo netstat -tlnp | grep :25

# Check Python installation
python3 --version
pip3 show aiosmtpd

# Check service logs
sudo journalctl -u smtpsink.service -xe
```

### Can't Connect to Port 25
1. Verify NSG rules allow port 25
2. Check if service is running: `sudo systemctl status smtpsink.service`
3. Test locally first: `telnet localhost 25`
4. Check VM public IP: `az vm show -g <RG> -n <VM> --show-details --query publicIps -o tsv`

### Emails Not Showing in Logs
1. Ensure the service is running
2. Check journald is working: `sudo journalctl -n 10`
3. Try verbose logging: `sudo journalctl -u smtpsink.service -f`

## Removing the SMTP Sink

To completely remove the SMTP sink functionality:

1. Stop and disable the service:
   ```bash
   sudo systemctl stop smtpsink.service
   sudo systemctl disable smtpsink.service
   ```

2. Remove the service file:
   ```bash
   sudo rm /etc/systemd/system/smtpsink.service
   sudo systemctl daemon-reload
   ```

3. Remove the Python script:
   ```bash
   sudo rm /opt/sirtunnel/smtp_sink.py
   ```

4. Update the Azure NSG to remove port 25 rule (redeploy Bicep after removing the rule)

## Integration with SirTunnel

The SMTP sink runs alongside SirTunnel and doesn't interfere with the HTTPS tunneling functionality. Both services can run simultaneously:

- SirTunnel: HTTPS on port 443
- SMTP Sink: SMTP on port 25
- SSH: Management on port 22

This allows you to test email functionality while maintaining your tunnel services.