# cad-worker: the headless CAD toolchain agents drive over MCP (P-DIL-53).
#
# One image, several servers: each k3s Deployment picks its server by args.
#   kicad      KiCad 10 via mixelpixx/KiCAD-MCP-Server (SWIG pcbnew backend),
#              stdio, exposed as Streamable HTTP by mcp-proxy
#   build123d  build123d-mcp in its own HTTP mode
# kicad-cli, SKiDL and build123d are also on PATH for CI jobs that use the image
# directly.
#
# Base pinned by digest, never by tag: KiCad 10.0.4 matches the kicad package in
# the nixpkgs laconchita's desktop runs, so a board saved in the GUI and one
# written by an agent are the same file format. Bump both together.
# The -full variant carries the 3D models (STEP export, renders, enclosure fit).
FROM kicad/kicad:10.0.4-full@sha256:fd4b9a49145872bbb1397d0eee4e10f50e69fbf25b1506d996216d120ff681e1

USER root

# The base gives its kicad user passwordless sudo. Nothing here needs root at
# runtime and the servers execute agent-written code, so take it away.
RUN gpasswd -d kicad sudo \
 && rm -f /etc/sudoers.d/* \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      nodejs \
      npm \
      python3-venv \
      libgl1 \
      libegl1 \
      libosmesa6 \
      libxrender1 \
      libxext6 \
 && rm -rf /var/lib/apt/lists/*

# One venv for every Python tool. --system-site-packages exposes KiCad's own
# pcbnew module (Debian's dist-packages) to it; pip never replaces pcbnew.
ENV VIRTUAL_ENV=/opt/cad
ENV PATH=/opt/cad/bin:$PATH
RUN python3 -m venv --system-site-packages /opt/cad

# KiCAD-MCP-Server, pinned to a release tag. `npm ci` runs its prepare script,
# which compiles the TypeScript; the dev dependencies are dropped afterwards.
ARG KICAD_MCP_VERSION=v2.8.2
RUN git clone --depth 1 --branch ${KICAD_MCP_VERSION} \
      https://github.com/mixelpixx/KiCAD-MCP-Server.git /opt/kicad-mcp \
 && cd /opt/kicad-mcp \
 && npm ci \
 && npm prune --omit=dev \
 && npm cache clean --force \
 && rm -rf .git

COPY requirements.txt /opt/cad/requirements.txt
RUN pip install --no-cache-dir \
      -r /opt/cad/requirements.txt \
      -r /opt/kicad-mcp/requirements.txt

# mcp-proxy (stdio servers -> Streamable HTTP) gets a venv of its own: 0.12.0
# imports mcp 1.x internals, while build123d-mcp needs mcp 2.x.
RUN python3 -m venv /opt/mcp-proxy \
 && /opt/mcp-proxy/bin/pip install --no-cache-dir 'mcp-proxy==0.12.0' 'mcp>=1.17,<2' \
 && ln -s /opt/mcp-proxy/bin/mcp-proxy /usr/local/bin/mcp-proxy

# The KiCad MCP server looks for its Python here before anything else, so it
# runs inside the venv and sees both pcbnew and its own requirements.
ENV KICAD_PYTHON=/opt/cad/bin/python

# KiCad's stock library locations, for SKiDL (which reads these variables) and
# for the library tables cad-entrypoint seeds. SKiDL 2.2.1 has no KiCad 10
# backend; its KICAD9 one reads the version-10 symbol files and looks them up
# through KICAD9_SYMBOL_DIR.
ENV KICAD_SYMBOL_DIR=/usr/share/kicad/symbols \
    KICAD9_SYMBOL_DIR=/usr/share/kicad/symbols \
    KICAD10_SYMBOL_DIR=/usr/share/kicad/symbols \
    KICAD10_FOOTPRINT_DIR=/usr/share/kicad/footprints \
    KICAD10_3DMODEL_DIR=/usr/share/kicad/3dmodels

COPY cad-entrypoint /usr/local/bin/cad-entrypoint

# Pods run as the host's cad user (uid/gid 1012, owner of /srv/cad), not as
# the base image's kicad user; HOME is pointed at a writable emptyDir there.
USER 1012:1012
WORKDIR /srv/cad
ENV HOME=/tmp/home
ENTRYPOINT ["/usr/local/bin/cad-entrypoint"]
CMD ["kicad-cli", "version"]
