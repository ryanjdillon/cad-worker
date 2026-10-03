# cad-worker

The headless CAD toolchain that agents drive over MCP on the home k3s cluster
(Linear project P-DIL-53, "CAD core"). One image runs several servers; each
Deployment picks one by its args.

| Server | Command | Transport |
| --- | --- | --- |
| KiCad 10 ([KiCAD-MCP-Server](https://github.com/mixelpixx/KiCAD-MCP-Server), SWIG backend) | `mcp-proxy --host 0.0.0.0 --port 9000 --stateless --pass-environment --cwd /srv/cad node /opt/kicad-mcp/dist/index.js` | stdio, served as Streamable HTTP at `/mcp` |
| [build123d-mcp](https://github.com/pzfreo/build123d-mcp) | `build123d-mcp --transport http --host 0.0.0.0 --port 9000` | Streamable HTTP at `/mcp` |

Also on `PATH` for CI jobs: `kicad-cli`, `python` with `pcbnew`, `build123d` and
`skidl`.

## Versions

- KiCad 10.0.4 (`kicad/kicad:10.0.4-full`, pinned by digest, 3D models included).
  It matches the `kicad` package of the nixpkgs laconchita's desktop runs, so the
  GUI and the agents read and write the same file format. Bump both together.
- KiCAD-MCP-Server is cloned by tag and checked against the tag's commit SHA.
- Every Python package is pinned with hashes: edit `requirements.in` or
  `mcp-proxy.in`, then recompile the locks with the image's own Python:

  ```sh
  docker run --rm -u 0 -v $PWD:/w -w /w -e HOME=/tmp --entrypoint sh cad-worker:dev -c \
    'python3 -m venv /tmp/pt && /tmp/pt/bin/pip -q install pip-tools &&
     for f in requirements mcp-proxy; do
       /tmp/pt/bin/pip-compile -q --generate-hashes --allow-unsafe --strip-extras -o $f.lock $f.in
     done'
  ```

  mcp-proxy has its own venv because it needs mcp 1.x while build123d-mcp needs
  mcp 2.x.
- The CI workflow is pinned to a commit of `ryanjdillon/workflows`.

## Runtime contract

- Runs as uid/gid 1012, `cad`, the host's user that owns `/srv/cad`.
- `HOME` is `/tmp/home`; mount a writable volume at `/tmp`. The entrypoint seeds
  KiCad's global library tables there (and the 9.0 link SKiDL needs).
- Project files live under `/srv/cad/<product>`, a hostPath shared with the
  laconchita desktop.
- The image has no sudo, no setuid/setgid binaries and no file capabilities. The
  Deployment must still set `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true` and drop all capabilities: the servers execute
  agent-written code.
- SKiDL writes `<script>.log` and `.erc` files into its working directory at
  import time. Run it from a scratch directory (or the product's build
  directory), not from a read-only path or a directory you want kept clean.

## Local smoke test

```sh
docker build -t cad-worker:dev .
docker run --rm --tmpfs /tmp cad-worker:dev kicad-cli version
```
