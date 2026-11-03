FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

WORKDIR /workspace

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        graphviz \
        jq \
        less \
        lsb-release \
        chromium \
        nodejs \
        npm \
        openssh-client \
        procps \
        unzip \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/microsoft-prod.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# Used by backend/scripts/start_lineage_web.sh to expose the local review app through
# a temporary Cloudflare quick tunnel when LINEAGE_WEB_PUBLIC_TUNNEL=true.
RUN npm install -g cloudflared@0.7.1 \
    && npm cache clean --force

# Keep Azure CLI and Fabric CLI in separate virtual environments because
# their Python dependency constraints can conflict.
RUN python -m pip install --upgrade pip \
    && python -m pip install \
        pandas \
        networkx \
        pyvis \
        pydot \
        graphviz \
        matplotlib \
        pyyaml \
    && python -m venv /opt/azure-cli \
    && /opt/azure-cli/bin/python -m pip install --upgrade pip \
    && /opt/azure-cli/bin/python -m pip install azure-cli==2.87.0 \
    && python -m venv /opt/fabric-cli \
    && /opt/fabric-cli/bin/python -m pip install --upgrade pip \
    && /opt/fabric-cli/bin/python -m pip install ms-fabric-cli==1.6.1 \
    && ln -s /opt/azure-cli/bin/az /usr/local/bin/az \
    && ln -s /opt/fabric-cli/bin/fab /usr/local/bin/fab

COPY docker/entrypoint.sh /usr/local/bin/fabric-mapper-entrypoint
RUN chmod +x /usr/local/bin/fabric-mapper-entrypoint

ENTRYPOINT ["/usr/local/bin/fabric-mapper-entrypoint"]
CMD ["bash"]

ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
