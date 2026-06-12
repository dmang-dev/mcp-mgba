# Dockerfile — primarily for the Glama MCP registry (https://glama.ai/mcp/servers).
#
# Builds the MCP server and runs it over stdio. The server starts cleanly
# WITHOUT mGBA present: it logs a note that the bridge is unreachable and
# still serves tools/list. That's exactly what Glama's "start + respond to
# introspection" check needs.
#
# For actual use you don't need Docker — `npm install -g mcp-mgba` and point
# it at a running mGBA with lua/bridge.lua loaded. See README.md.

FROM node:22-trixie-slim
WORKDIR /app

# Install dependencies. --ignore-scripts skips the `prepare` hook; we run the
# build explicitly below so the layer caching is predictable.
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

# Compile TypeScript -> dist/
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

# Ship the Lua bridge alongside (not used by the Node server itself — it's
# loaded into mGBA — but handy if someone docker-cp's it out).
COPY lua/ ./lua/

# The MCP server speaks JSON-RPC over stdio.
ENTRYPOINT ["node", "dist/index.js"]
