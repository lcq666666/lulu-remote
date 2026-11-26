# host-setup — remote PC setup

`install-sunshine.ps1` runs **on the remote Windows PC** (Administrator
PowerShell). It installs Sunshine + Tailscale via winget, opens the
firewall ports, starts Sunshine, and opens the web UI so the admin
account can be created.

It does not create the admin account, pair anything, or change passwords.

The LULU launcher's setup-checklist screen shows the exact command to
run it. The script has not been run on a real Windows machine yet —
watch it the first time.
