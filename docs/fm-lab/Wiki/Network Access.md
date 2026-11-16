# Network Access

fm-lab is built for one workstation. The web client runs on a development server, and the REST API has no sign-in and answers requests from any web page. Keep both reachable only from your own computer, and reach a server or VM through an SSH tunnel rather than through the network.

## Who can reach fm-lab

| Setup | Web client (5173) and REST API (3003) |
|---|---|
| **Native** (`tools/init.sh`, `bash tools/fmlab.sh up` → *No*) | only this computer — both listen on `localhost` unless you set `VITE_DEV_HOST` or `HOST` |
| **VS Code Dev Container** | only this computer — VS Code forwards the ports to `localhost` |
| **Docker** (`bash tools/fmlab.sh up`, `docker compose up`) | **every computer that can reach this one** — Docker publishes both ports on all network interfaces of the host |

Whoever reaches the web client can use everything fm-lab offers, and the development server also hands out files of the fm-lab folder: the catalogs of all solutions, the XML exports and the settings. The `X-FMLab-User` header names the author of a change; it is no sign-in.

## Working on a server or VM: SSH tunnel

If fm-lab runs on another machine, leave it bound to `localhost` there and open a tunnel from your workstation:

```bash
ssh -N -L 5173:localhost:5173 <user>@<server>
```

Then open `http://localhost:5173` on your workstation. The web client forwards `/api` to the REST API on the server, so one tunnel is enough. Tools on your workstation that call the API directly need a second forward: add `-L 3003:localhost:3003`. SSH brings encryption and sign-in; nothing else has to be opened on the server.

## Do not set `VITE_DEV_HOST=0.0.0.0` on a shared network

`VITE_DEV_HOST=0.0.0.0` (and `HOST=0.0.0.0` for the API) makes fm-lab listen on every network interface — everyone in the network can then use it as described above. The Dev Container sets it only inside the container, where VS Code forwards the ports to `localhost`. On a native installation keep the default and use the tunnel instead.

## Docker on a shared network

Until the Docker setup binds to `localhost` by default (planned), restrict the two ports on the host:

- **Run Docker on a machine others cannot reach**, for example your own laptop outside a shared network, and use the tunnel above for a server.
- **Firewall:** block incoming connections to ports 3003 and 5173 from other machines. On Linux, ports published by Docker **bypass `ufw`** — rules for them belong in the `DOCKER-USER` chain of iptables, or in a network or cloud firewall in front of the host. On macOS and Windows, Docker Desktop accepts connections from the network as well; the operating system's firewall decides whether they arrive.

## If access from other machines is unavoidable

Allow only the machines that need it, and nothing else:

```bash
# Linux, native installation (ufw) — 192.168.10.0/24 stands for your admin network
sudo ufw allow from 192.168.10.0/24 to any port 5173 proto tcp
sudo ufw deny 5173/tcp
sudo ufw deny 3003/tcp
```

The REST API stays on `localhost` in that case; the web client forwards `/api` to it. A mode without the development server, with sign-in and HTTPS, is planned.

See also: [Installation](Installation.md), [Troubleshooting](Troubleshooting.md).
