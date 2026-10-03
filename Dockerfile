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

# The servers execute agent-written code, so nothing in the image may lead back
# to root:
# - the base gives its kicad user passwordless sudo; take that away;
# - strip every setuid/setgid bit and the one file capability (gst-ptp-helper).
#   cap-drop ALL alone would not stop a setuid exec from becoming uid 0; the
#   Deployment's allowPrivilegeEscalation: false does, and this is the second
#   layer.
# The pods run as the host's cad user (uid/gid 1012, owner of /srv/cad); give it
# a passwd entry so getpwuid() callers (git, ssh, getpass) get a name.
RUN gpasswd -d kicad sudo \
 && rm -f /etc/sudoers.d/* \
 && find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod a-s {} + \
 && setcap -r /usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper \
 && groupadd --gid 1012 cad \
 && useradd --uid 1012 --gid 1012 --no-create-home --home-dir /tmp/home \
      --shell /usr/sbin/nologin cad \
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

# KiCAD-MCP-Server, pinned to the commit behind its release tag: the tag names
# the version, the SHA makes a moved tag fail the build instead of changing
# what runs. `npm ci` checks package-lock.json integrity and runs the prepare
# script, which compiles the TypeScript; the dev dependencies are dropped after.
ARG KICAD_MCP_VERSION=v2.8.2
ARG KICAD_MCP_COMMIT=670d2a9c48e1588f2e07edaf656b5e301fc55a50
RUN git clone --depth 1 --branch ${KICAD_MCP_VERSION} \
      https://github.com/mixelpixx/KiCAD-MCP-Server.git /opt/kicad-mcp \
 && cd /opt/kicad-mcp \
 && test "$(git rev-parse HEAD)" = "${KICAD_MCP_COMMIT}" \
 && npm ci \
 && npm prune --omit=dev \
 && npm cache clean --force \
 && rm -rf .git

# Every Python package is pinned and hash-checked: requirements.lock is compiled
# from requirements.in, which also lists KiCAD-MCP-Server's Python dependencies
# (its own requirements.txt only gives lower bounds).
COPY requirements.lock /opt/cad/requirements.lock
RUN pip install --no-cache-dir --require-hashes -r /opt/cad/requirements.lock

# mcp-proxy (stdio servers -> Streamable HTTP) gets a venv of its own: 0.12.0
# imports mcp 1.x internals, while build123d-mcp needs mcp 2.x.
COPY mcp-proxy.lock /opt/mcp-proxy.lock
RUN python3 -m venv /opt/mcp-proxy \
 && /opt/mcp-proxy/bin/pip install --no-cache-dir --require-hashes -r /opt/mcp-proxy.lock \
 && ln -s /opt/mcp-proxy/bin/mcp-proxy /usr/local/bin/mcp-proxy

# The KiCad MCP server looks for its Python here before anything else, so it
# runs inside the venv and sees both pcbnew and its own requirements.
ENV KICAD_PYTHON=/opt/cad/bin/python

# KiCad's stock library locations. SKiDL 2.2.1 has no KiCad 10 backend; its
# KICAD9 one reads the version-10 symbol files through KICAD9_SYMBOL_DIR, and
# looks for the footprint table under ~/.config/kicad/9.0, which cad-entrypoint
# links to the 10.0 one it seeds.
ENV KICAD_SYMBOL_DIR=/usr/share/kicad/symbols \
    KICAD9_SYMBOL_DIR=/usr/share/kicad/symbols \
    KICAD10_SYMBOL_DIR=/usr/share/kicad/symbols \
    KICAD10_FOOTPRINT_DIR=/usr/share/kicad/footprints \
    KICAD10_3DMODEL_DIR=/usr/share/kicad/3dmodels

COPY cad-entrypoint /usr/local/bin/cad-entrypoint

USER 1012:1012
WORKDIR /srv/cad
ENV HOME=/tmp/home
ENTRYPOINT ["/usr/local/bin/cad-entrypoint"]
CMD ["kicad-cli", "version"]
