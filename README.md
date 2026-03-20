# theshed-zomboid

A Docker container for a Project Zomboid dedicated server. Configure everything via a single `.env` file — server settings, sandbox variables, and mods pulled directly from a Steam Workshop collection.

## Features

- **Single `.env` config** — server properties and sandbox vars are all env vars
- **Steam collection support** — point at a collection URL and mods are fetched, downloaded, and wired up automatically
- **Beta branch support** — pin to any Steam beta branch (e.g. `iwbums`)
- **Automatic updates** — server and mods update on each container restart (configurable)
- **Separated volumes** — server binaries and game data (saves, config, logs) in separate bind mounts

## Quick Start

```bash
git clone https://github.com/fillier/theshed-zomboid.git
cd theshed-zomboid
cp .env.example .env
```

Edit `.env` to set your server name, admin password, and any mods you want, then:

```bash
docker compose up -d
docker compose logs -f
```

The server binaries (~3GB) will download on the first run via SteamCMD.

## Configuration

All configuration lives in `.env`. See [`.env.example`](.env.example) for the full reference with comments.

### Core Settings

| Variable | Default | Description |
|---|---|---|
| `SERVER_NAME` | `zomboid` | Server name (used for config filenames) |
| `ADMIN_PASSWORD` | `changeme` | Server admin password |
| `SERVER_PORT` | `16261` | Primary UDP game port |
| `RCON_PORT` | `27015` | RCON TCP port |
| `UPDATE_ON_START` | `true` | Re-run SteamCMD on each restart |
| `UPDATE_MODS` | `true` | Re-download workshop mods on each restart |
| `BETA_BRANCH` | *(empty)* | Target a Steam beta branch (e.g. `iwbums`) |

### Mods — Steam Collection

Set `STEAM_COLLECTION_ID` to the numeric ID from your Steam Workshop collection URL:

```
https://steamcommunity.com/sharedfiles/filedetails/?id=2982072751
                                                       ^^^^^^^^^^
```

```env
STEAM_COLLECTION_ID=2982072751
```

On startup the container will:
1. Fetch all workshop item IDs from the collection via the Steam API
2. Download each item via SteamCMD
3. Parse the `mod.info` files to get the PZ mod IDs
4. Auto-populate `Mods=` and `WorkshopItems=` in the server config

To include individual mods not in the collection, add them as a comma-separated list:

```env
EXTRA_WORKSHOP_IDS=2392847436,2100026811
```

### Server Properties

Any `PZ_INI_Key=Value` in `.env` maps directly to `Key=Value` in the server `.ini` file:

```env
PZ_INI_Public=true
PZ_INI_PublicName=The Shed
PZ_INI_MaxPlayers=16
PZ_INI_PVP=false
PZ_INI_Map=Muldraugh, KY
```

### Sandbox Variables

Any `PZ_SBX_Key=Value` in `.env` maps to `Key = Value` in `SandboxVars.lua`:

```env
PZ_SBX_Zombies=4        # 1=Insane 2=VeryHigh 3=High 4=Normal 5=Low 6=None
PZ_SBX_Loot=3           # 1=None 2=Scarce 3=Normal 4=Abundant 5=Insane
PZ_SBX_XpMultiplier=2.0
PZ_SBX_ZombieRespawn=0  # 0 = never respawn
```

See the [PZ wiki](https://pzwiki.net/wiki/Server_Settings) for the full list of sandbox options and their numeric values.

## Volumes

Two named Docker volumes are created automatically:

| Volume | Mount | Contents |
|---|---|---|
| `pz-server` | `/server` | PZ dedicated server binaries (~3GB) |
| `pz-data` | `/data` | Saves, server config, logs — **back this up** |

To use local bind mounts instead, replace the volume definitions in `docker-compose.yml`:

```yaml
volumes:
  - ./server:/server
  - ./data:/data
```

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| `16261` | UDP | Primary game port |
| `16262` | UDP | Secondary game port (always primary + 1) |
| `27015` | TCP | RCON |

## Updating

**Server update:** Set `UPDATE_ON_START=true` (default) and restart the container.

**Mod update:** Set `UPDATE_MODS=true` (default) and restart. Mods are re-downloaded from Steam.

To skip updates for faster restarts once everything is installed:

```env
UPDATE_ON_START=false
UPDATE_MODS=false
```

## Steam Credentials

Anonymous SteamCMD login works for the dedicated server and most workshop mods. If you hit `No subscription` errors for specific mods, provide a Steam account that owns PZ:

```env
STEAM_USERNAME=your_steam_username
STEAM_PASSWORD=your_steam_password
```
