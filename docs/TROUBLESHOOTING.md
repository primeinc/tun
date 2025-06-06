# SirTunnel Troubleshooting Guide

This document provides solutions for common issues encountered when using SirTunnel.

## Configuration and Setup Issues

### Working with DryRun Mode

**Problem:** Needing to test or configure locally without actual Azure deployments.

**Solutions:**
- Use the `-DryRun` parameter to set up local files only
- Specify an IP address with the new `-IpOverride` parameter: `.\redeploy-extension.ps1 -DryRun -IpOverride "20.30.40.50"`
- Add a permanent override in your config.ps1: `$VM_IP_OVERRIDE = "20.30.40.50"`

**Example:** Dry run with IP from existing tunnel:
```powershell
# Get current IP from existing tunnel
$ip = (Get-Content "$HOME/.tun/last.json" | ConvertFrom-Json).vmIp
# Run setup with that IP
.\scripts\redeploy-extension.ps1 -DryRun -IpOverride $ip
```

## Connection Issues

### SSH Connection Refused

**Problem:** Cannot establish SSH connection to the VM.

**Possible Solutions:**
- Verify the VM is running in the Azure portal
- Confirm the public IP address is correct
- Check that port 22 is open in the Network Security Group
- Verify your SSH key is correctly configured

### Host Key Verification Failed

**Problem:** SSH connection fails with "Host key verification failed" error.

**Possible Solutions:**
- Use the `-Force` parameter when creating the tunnel: `tun api 3000 -Force`
- Manually remove the host key entry: `ssh-keygen -R <vm-ip-address>`
- If you're certain the host is legitimate, you can use `ssh -o StrictHostKeyChecking=no` for a one-time connection

**Explanation:** This happens when the VM's SSH key changes, which is common after VM redeployments or recreations. The latest version of SirTunnel attempts to automatically handle these issues when it detects existing host keys.

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

### SeSecurityPrivilege Errors

**Problem:** You see errors related to "SeSecurityPrivilege" or "The process does not possess the 'SeSecurityPrivilege' privilege which is required for this operation" when creating tunnels or running the setup scripts.

**Possible Solutions:**
- The latest version of SirTunnel automatically detects privilege levels and works in non-admin mode
- Run PowerShell as Administrator if you need secure file permissions
- Use the `-DryRun` parameter with `redeploy-extension.ps1` to set up the module without requiring elevated privileges

**Explanation:** SirTunnel attempts to set secure ACL permissions on its configuration files, which requires the SeSecurityPrivilege. When running as a standard user, these operations will now gracefully fallback to standard permissions.

### File Access Denied Issues

**Problem:** You can't access or modify files in the `.tun` directory.

**Possible Solutions:**
- Check file ownership: `Get-Acl "$HOME/.tun"`
- Ensure your user account has access to these files
- If running in a corporate environment, check with your IT department about file access policies
- Use standard file permissions by running: `Initialize-TunnelEnvironment -SkipSecurePermissions`

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

### "DeploymentStackInNonTerminalState" Error During Cleanup

**Problem:** The `deploy.ps1` script (or manual `az stack group delete`) fails with an error similar to "DeploymentStackInNonTerminalState" or "Operation Canceled". This typically means the underlying ARM deployment for the stack is still active or in a state that prevents immediate deletion (e.g., 'Deploying', 'Provisioning', 'Canceling', or certain 'Failed' states).

**Automated Script Handling:**
- The `deploy.ps1` script attempts to handle this automatically when you choose to delete a stack that is in a 'Deploying' or 'Provisioning' state.
- It will first try to find and cancel the active underlying ARM deployment associated with the stack.
- It waits for a short period after attempting cancellation before trying to delete the stack again.

**Manual Steps (if automated handling fails or for other non-terminal states):**
1.  **Identify the Active Deployment:**
    *   Go to the Azure portal, navigate to your resource group (`$VM_RG_NAME`).
    *   In the "Deployments" section, find the deployment related to your stack (often named similarly to the stack, e.g., `<STACK_NAME>_....`). Look for deployments with a status of 'Running', 'Deploying', 'Provisioning', 'Canceling', or a recent 'Failed' state that might be blocking the stack deletion.
    *   Note the **Name** of this active or problematic deployment.
2.  **Cancel the Active Deployment via Azure CLI:**
    ```bash
    az deployment group cancel --resource-group YOUR_RESOURCE_GROUP_NAME --name ACTIVE_DEPLOYMENT_NAME_FROM_PORTAL
    ```
    Replace `YOUR_RESOURCE_GROUP_NAME` and `ACTIVE_DEPLOYMENT_NAME_FROM_PORTAL` with the correct values.
3.  **Wait and Retry Stack Deletion:**
    *   Wait a few minutes for the cancellation to complete. You can check its status in the Azure portal.
    *   Once the underlying deployment is no longer in an active or problematic state (e.g., it shows 'Canceled' or 'Failed' in a way that's not blocking), try deleting the stack again using the `deploy.ps1` script or manually:
        ```bash
        az stack group delete --name YOUR_STACK_NAME --resource-group YOUR_RESOURCE_GROUP_NAME --yes --action-on-unmanage deleteResources
        ```
4.  **Persistent Issues:**
    *   If the deployment refuses to cancel or the stack still won't delete, there might be a resource lock or an Azure platform issue. Check for any resource locks on the resources or resource group.
    *   You may need to wait longer or, in rare cases, contact Azure support.

## Getting Help

If you continue to experience issues:

1. Check Azure resource logs in the portal
2. Review the complete VM extension logs
3. SSH into the VM for direct troubleshooting
4. Consider opening an issue in the GitHub repository with logs and details
