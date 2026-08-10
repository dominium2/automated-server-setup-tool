# Reset SSH Host Keys (ResetKeys)

This document explains how to clear cached SSH host keys when a VM is rebuilt and the host fingerprint changes.

## Why This Is Needed

After recreating a VM on the same IP, SSH clients may show:

`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`

This usually means the machine was rebuilt and now has a new host key. Your client still trusts the old key, so it blocks the connection.

## What `resetKeys.ps1` Does

The script clears PuTTY/Plink cached host keys for a specific IP from:

`HKCU:\Software\SimonTatham\PuTTY\SshHostKeys`

This is useful for connections made through PuTTY-based tooling.

## Script Location

- [resetKeys.ps1](../resetKeys.ps1)

## Default Target

The current script call clears keys for:

- `192.168.56.11`

## How To Run

From the project root:

```powershell
.\resetKeys.ps1
```

Expected result:

- Success message if matching PuTTY keys were removed.
- Warning message if no matching key exists.

## OpenSSH Note (Important)

If you connect with `ssh` (Windows OpenSSH), the host key is stored in:

`$HOME\.ssh\known_hosts`

In that case, run:

```powershell
ssh-keygen -R 192.168.56.11
```

Then reconnect:

```powershell
ssh testuser@192.168.56.11
```

## Quick Troubleshooting

1. Recreated VM and now SSH fails with host key mismatch: run `ssh-keygen -R <ip>`.
2. Using PuTTY/Plink tooling and key mismatch persists: run `./resetKeys.ps1`.
3. Still failing: verify you are connecting to the correct IP and VM instance.

## Security Reminder

Only clear host keys when you expect a legitimate key change (for example after `vagrant destroy` and reprovision). If you are unsure, verify the host fingerprint out-of-band before reconnecting.