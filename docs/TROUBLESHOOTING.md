# SirTunnel Troubleshooting Guide

This document provides solutions for common issues encountered when using SirTunnel.

## Connection Issues

### SSH Connection Refused

**Problem:** Cannot establish SSH connection to the VM.

**Possible Solutions:**
- Verify the VM is running in the Azure portal
- Confirm the public IP address is correct
- Check that port 22 is open in the Network Security Group
- Verify your SSH key is correctly configured

### Tunnel Not Accessible

**Problem:** SSH connection succeeds but https://<subdomain>.tun.title.dev is not accessible.

**Possible Solutions:**
- Verify DNS propagation using `dig <subdomain>.tun.title.dev`
- Check if Caddy is running on the VM: `sudo systemctl status caddy`
- Verify local service is running and accessible on the specified port
- Check Caddy logs: `sudo journalctl -u caddy --no-pager`

## Certificate Issues

### Certificate Not Issued

**Problem:** HTTPS connection shows certificate errors or invalid certificate warnings.

**Possible Solutions:**
- Verify the VM's managed identity has DNS Zone Contributor role
- Check Caddy logs for ACME challenge errors
- Ensure the Azure DNS resource group and subscription ID are correctly configured
- It might take a few minutes for Let's Encrypt to issue the certificate on first use

### Rate Limit Exceeded

**Problem:** Let's Encrypt rate limit errors in Caddy logs.

**Possible Solution:**
- Let's Encrypt has [rate limits](https://letsencrypt.org/docs/rate-limits/) on certificate issuance
- For testing, modify the Caddy config to use Let's Encrypt staging environment
- Wait at least an hour before retrying

## VM Issues

### VM Extension Failure

**Problem:** The VM Custom Script Extension fails during deployment.

**Possible Solutions:**
- Check the extension logs in the Azure portal
- SSH into the VM and check `/var/log/azure/custom-script/handler.log`
- Verify the install.sh script is accessible at the configured URL

### Caddy Not Configured Properly

**Problem:** Caddy is running but not accepting connections or has configuration errors.

**Possible Solutions:**
- Check Caddy logs: `sudo journalctl -u caddy --no-pager`
- Verify the Caddy configuration: `sudo caddy validate --config /etc/caddy/Caddyfile`
- Manually restart Caddy: `sudo systemctl restart caddy`

## Permissions Issues

### Managed Identity Cannot Modify DNS

**Problem:** Caddy logs show permission denied errors for DNS challenges.

**Possible Solutions:**
- Verify the role assignment was created successfully
- Check that the VM's managed identity has "DNS Zone Contributor" role on the DNS zone
- Confirm the DNS zone name and resource group are correct
- It can take a few minutes for role assignments to propagate

## Local Service Issues

### Local Service Not Reachable Through Tunnel

**Problem:** The tunnel is established but requests don't reach the local service.

**Possible Solutions:**
- Verify the local service is listening on the specified interface and port
- Check if any local firewall is blocking inbound connections
- Try using `localhost` instead of `127.0.0.1` or vice versa
- For non-localhost services, ensure your machine can route to that IP

## Stale Routes in Caddy

**Problem:** Previous tunnel configurations persist after they should be removed.

**Possible Solutions:**
- SSH into the VM and check Caddy's current configuration: `curl http://localhost:2019/config/`
- Remove stale routes manually via Caddy's admin API
- Restart Caddy as a last resort: `sudo systemctl restart caddy`

## Resource Cleanup

### Resources Not Deleted

**Problem:** Some resources remain after deleting the stack.

**Possible Solutions:**
- Check if resources are in a failed state in the Azure portal
- Try deleting resources manually
- Verify the `--action-on-unmanage deleteResources` flag is used when deleting the stack

## Getting Help

If you continue to experience issues:

1. Check Azure resource logs in the portal
2. Review the complete VM extension logs
3. SSH into the VM for direct troubleshooting
4. Consider opening an issue in the GitHub repository with logs and details
