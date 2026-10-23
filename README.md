# Bulky installer

Installs [Bulky](https://usebulky.com) on a fresh Ubuntu 22.04 or 24.04 (amd64)
server with DNS already pointing at it:

```sh
curl -fsSL https://access.usebulky.com/install | sudo bash
```

(`https://access.usebulky.com/install` redirects to
`https://raw.githubusercontent.com/usebulky/install/main/install.sh`.)

It asks for the hostname, the first admin's email and password, and your
license key, then downloads the newest release your license allows from
`access.usebulky.com` (verifying its SHA-256), prepares the server (Docker,
firewall, security updates), installs and activates Bulky, and offers to set
up encrypted backups.

Set `BULKY_DATA_DIR` for a data directory other than `/srv/bulky`:

```sh
curl -fsSL https://access.usebulky.com/install | sudo BULKY_DATA_DIR=/data/bulky bash
```

Read the script before running it if you like; it contains no secrets; your
license key is what authorizes the download.
