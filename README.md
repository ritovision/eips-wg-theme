# EIPs Theme

Zola theme used by the Ethereum Improvement Proposal (EIP) site, including EIPs
and ERCs. This repo contains the shared templates, Sass, static assets, syntax
definitions, and Zola configuration used when rendering proposal content.

## Local Workspace Setup

Use the setup script to bootstrap the surrounding local `build-eips` workspace:

```sh
./scripts/dev-setup
```

The theme repo is not itself an active proposal repo, so the script anchors
workspace setup through a sibling proposal checkout. By default it uses
`../EIPs`; override that with `ACTIVE_REPO_ROOT` when needed:

```sh
ACTIVE_REPO_ROOT=../ERCs ./scripts/dev-setup
```

Default setup provisions the active proposal repo, sibling proposal repo,
`theme`, `.build-eips.toml`, and `.local-build/`.

Pass optional flags through the script when you need extra repos:

```sh
./scripts/dev-setup --template
./scripts/dev-setup --platform-dev
./scripts/dev-setup --template --platform-dev
```

After setup, run local site commands against the active proposal repo:

```sh
build-eips -C ../EIPs check
build-eips -C ../EIPs serve
build-eips -C ../EIPs workspace doctor
```
