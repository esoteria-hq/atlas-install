<div align="center">

# Atlas — installer

**A voice-first personal AI agent for your Mac.** · [esoteria.ai](https://esoteria.ai)

</div>

---

## Install (macOS, Apple Silicon)

esoteria will send you a one-line command containing **your** server URL and a
personal access token. It looks like this:

```bash
ATLAS_SERVER_URL='http://<your-server>:8443' ATLAS_CLIENT_TOKEN='<your-token>' \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/esoteria-hq/atlas-install/main/client-install.sh)"
```

That installs the Atlas **thin client** — the app UI only. The agent itself runs
on esoteria's managed server, in your own isolated profile. **No API keys, no
source code, nothing sensitive** is placed on your Mac or stored in this repo.

## What's in this repo

- `client-install.sh` — the installer the one-liner runs
- Releases -> `atlas-client.tar.gz` — the opaque Electron UI bundle

The Atlas product (agent, prompts, skills, keys) stays on esoteria's private infrastructure.
