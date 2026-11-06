# gwtor

gwtor runs several Tor instances, each sending all of its traffic through
its own WireGuard tunnel, and puts [gwproxy](https://github.com/ammarfaizi2/gwproxy)
in front of them as one load-balancing SOCKS5 and HTTP proxy.

```
                         gwtor network 10.185.100.0/24
                     +------------------------------------+
  client  ---------> | gwproxy  10.185.100.2:9999          |
  (SOCKS5 or HTTP)   |   round-robin over every Tor port   |
                     |                                    |
                     |   tor-a  10.185.100.3:8000-8009 ---+--> wg0 --> VPN A --> Tor
                     |   tor-b  10.185.100.4:8000-8009 ---+--> wg0 --> VPN B --> Tor
                     |   tor-c  10.185.100.5:8000-8009 ---+--> wg0 --> VPN C --> Tor
                     +------------------------------------+
```

- **One Tor container per WireGuard config** in `wg/`. Each one brings
  up its tunnel as `wg0` and makes it the only way out: the routing table
  keeps just the container's own subnet, a host route to the WireGuard
  endpoint, and a default route through `wg0`. If the tunnel goes away,
  traffic stops instead of leaking out of the host's own connection. DNS
  also goes through the tunnel.
- **10 SOCKS5 ports per Tor instance** (8000-8009). Streams on different
  ports never share a Tor circuit, so each port usually exits from a
  different Tor exit.
- **gwproxy** listens on `[::]:9999` and speaks SOCKS5 and HTTP (CONNECT
  and plain forwarding) on that one port, telling them apart by the first
  bytes of each connection. It requires a username and password, and it
  sends each connection to the next Tor SOCKS port in turn, alternating
  between instances so consecutive connections use different tunnels.
- **Built from source** with clang 23 and ThinLTO: Tor 0.4.9.16 and
  gwproxy, both tracked as git submodules.

## Requirements

- Linux with the `wireguard` kernel module (the containers create their
  own `wg0` interface and need `NET_ADMIN`).
- Docker with Compose v2.
- One WireGuard config per Tor instance, in wg-quick format, with an IPv4
  `Endpoint` and `AllowedIPs = 0.0.0.0/0, ::/0` (configs from VPN
  providers such as Proton VPN work as they are).

## Setup

Clone with the submodules:

```bash
git clone --recurse-submodules <url> gwtor
cd gwtor
```

(For an existing clone: `git submodule update --init`.)

Put the WireGuard configs in `wg/`, one file per Tor instance. The file
name, without `.conf`, names the instance and may contain only lowercase
letters, digits, `_` and `-`:

```
wg/fra002.conf
wg/hel001.conf
wg/vie002.conf
```

`wg/` is git-ignored, since the configs hold private keys.

Generate the per-instance files, then build and start everything:

```bash
./gen-compose.sh
docker compose up -d --build
```

The first build takes a few minutes. The Tor containers report
`healthy` once Tor has finished bootstrapping:

```bash
docker compose ps
```

## Usage

Point any SOCKS5 or HTTP client at `10.185.100.2:9999`, with the
credentials from `run/gwproxy/auth.txt` (initially user `gwproxy`,
password `e70ed37f7ec082d0aa`):

```bash
curl -x socks5h://gwproxy:e70ed37f7ec082d0aa@10.185.100.2:9999 https://ip.me
curl -x http://gwproxy:e70ed37f7ec082d0aa@10.185.100.2:9999 https://ip.me
```

Each request should print a different Tor exit address, never your own.
Use `socks5h://` rather than `socks5://`, so names are resolved through
Tor rather than locally.

The network is reachable from the Docker host. To use gwtor from other
machines, publish the port, for example in `compose.yaml`:

```yaml
  gwproxy:
    ports:
      - "9999:9999"
```

### Using one Tor instance directly

The Tor SOCKS ports accept clients from the gwtor network, so the host
can also use one instance, or one port, directly, without
authentication:

```bash
curl --socks5-hostname 10.185.100.3:8000 https://ip.me
```

### Managing users

`run/gwproxy/auth.txt` holds one `username:password` per line, shared by
SOCKS5 and HTTP. After editing it, tell gwproxy to reload:

```bash
docker compose kill -s HUP gwproxy
```

`gen-compose.sh` creates the file only when it does not exist yet and
never overwrites it, so added users survive a rerun. To start with
other credentials, set them for the first run:

```bash
GWPROXY_USER=alice GWPROXY_PASS='s3cret' ./gen-compose.sh
```

### Adding or removing a tunnel

Add or remove a config in `wg/`, then regenerate and apply:

```bash
./gen-compose.sh
docker compose up -d --remove-orphans
```

Instances take the addresses 10.185.100.3, .4, ... in name order, so
adding a config can move the instances after it to new addresses.

### Checking a tunnel

```bash
# The tunnel's own exit address (not Tor's) -- must not be the host's:
docker compose exec tor-fra002 curl -s https://ip.me

# The WireGuard handshake and the routes:
docker compose exec tor-fra002 wg show wg0
docker compose exec tor-fra002 ip route

# Tor's log:
docker compose logs -f tor-fra002
```

### Stopping

```bash
docker compose down
```

Tor's state (guards, the cached consensus) lives in one volume per
instance, so a restart bootstraps quickly. `docker compose down -v`
removes those volumes too.

## Configuration

`gen-compose.sh` reads these environment variables:

| Variable              | Default              | Meaning                                  |
|-----------------------|----------------------|------------------------------------------|
| `GWTOR_SUBNET_PREFIX` | `10.185.100`         | First three octets of the gwtor network  |
| `GWTOR_FIRST_HOST`    | `3`                  | Last octet of the first Tor container    |
| `GWTOR_SOCKS_PORTS`   | `8000-8009`          | SOCKS port range of every Tor instance   |
| `GWPROXY_USER`        | `gwproxy`            | Initial gwproxy user                     |
| `GWPROXY_PASS`        | `e70ed37f7ec082d0aa` | Initial gwproxy password                 |

The network itself (subnet, gateway, gwproxy's address) is set in
`compose.yaml`; change `GWTOR_SUBNET_PREFIX` to match if you move it.

The Tor container's entrypoint takes these, set through `environment:`
of a `tor-*` service:

| Variable           | Default              | Meaning                                         |
|--------------------|----------------------|-------------------------------------------------|
| `WG_DNS`           | `1.1.1.1`            | Resolvers, used when the config has no `DNS` line |
| `TOR_SOCKS_PORTS`  | `8000-8009`          | SOCKS port range                                |
| `TOR_SOCKS_ACCEPT` | `10.185.100.0/24`    | Networks allowed to use the SOCKS ports         |
| `TOR_EXTRA_CONF`   | (empty)              | Extra lines appended to the generated torrc     |

## Files

| Path                        | What it is                                             |
|-----------------------------|--------------------------------------------------------|
| `compose.yaml`              | Network, gwproxy, and the Tor image build              |
| `gen-compose.sh`            | Writes the generated files below from `wg/*.conf`      |
| `compose.override.yaml`     | Generated: one `tor-<name>` service per config         |
| `run/gwproxy/acl.txt`       | Generated: gwproxy's upstream pool of Tor SOCKS ports  |
| `run/gwproxy/auth.txt`      | gwproxy's credentials, created once                    |
| `docker/gwproxy/Dockerfile` | gwproxy image                                          |
| `docker/tor/Dockerfile`     | Tor image                                              |
| `docker/tor/entrypoint.sh`  | Brings up the tunnel, writes the torrc, starts Tor     |
| `gwproxy/`, `tor/`          | Source submodules                                      |
| `wg/`                       | Your WireGuard configs (git-ignored)                   |

## Limits

- gwproxy caps an upstream pool at 64 servers, so with 10 ports per
  instance, gwtor runs at most six WireGuard configs. `gen-compose.sh`
  refuses more.
- WireGuard endpoints must be IPv4, since the gwtor network is IPv4 only.
  Traffic inside the tunnel may still use IPv6.
- Tor is built as a client only; it cannot run as a relay.
