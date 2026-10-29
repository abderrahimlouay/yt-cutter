#!/usr/bin/env bash
# add_docker.sh - adds the Docker setup, a GitHub Actions CI workflow and README updates.
# Run from the yt-cutter project root:  bash add_docker.sh
set -euo pipefail

ROOT="${1:-.}"

[ -f "$ROOT/backend/requirements.txt" ] && [ -f "$ROOT/frontend/package.json" ] \
  || { echo "Run this from the yt-cutter project root." >&2; exit 1; }

echo "[*] Writing Docker files"

# ------------------------------------------------------------------ backend image
cat > "$ROOT/backend/Dockerfile" <<'EOF'
# Node is copied in because yt-dlp needs a JavaScript runtime to solve YouTube challenges.
FROM node:22-slim AS node

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    YTCUTTER_JS_RUNTIME=node \
    YTCUTTER_CLIPS_DIR=/tmp/yt-cutter

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/health').status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > "$ROOT/backend/.dockerignore" <<'EOF'
.venv/
__pycache__/
*.py[cod]
.pytest_cache/
.ruff_cache/
tests/
.env
EOF

# ------------------------------------------------------------------ frontend image
cat > "$ROOT/frontend/Dockerfile" <<'EOF'
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:stable-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
EOF

cat > "$ROOT/frontend/nginx.conf" <<'EOF'
server {
  listen 80;
  server_name _;

  root /usr/share/nginx/html;
  index index.html;

  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "DENY" always;
  add_header Referrer-Policy "no-referrer" always;

  # API + Server-Sent Events: no buffering so progress arrives live
  location /api/ {
    proxy_pass http://backend:8000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 1h;
  }

  location / {
    try_files $uri /index.html;
  }
}
EOF

cat > "$ROOT/frontend/.dockerignore" <<'EOF'
node_modules/
dist/
.env
EOF

# ------------------------------------------------------------------ compose
cat > "$ROOT/docker-compose.yml" <<'EOF'
services:
  backend:
    build: ./backend
    restart: unless-stopped
    environment:
      YTCUTTER_JS_RUNTIME: node
      YTCUTTER_CLIPS_DIR: /tmp/yt-cutter
      YTCUTTER_ALLOWED_HOSTS: '["localhost","127.0.0.1"]'
    # clips live in memory-backed storage and disappear when the container stops
    tmpfs:
      - /tmp/yt-cutter:uid=10001,gid=10001,size=2g
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    expose:
      - "8000"          # reachable only inside the compose network

  frontend:
    build: ./frontend
    restart: unless-stopped
    depends_on:
      backend:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    ports:
      - "127.0.0.1:8080:80"   # localhost only
EOF

# ------------------------------------------------------------------ CI
echo "[*] Writing GitHub Actions workflow"
mkdir -p "$ROOT/.github/workflows"
cat > "$ROOT/.github/workflows/ci.yml" <<'EOF'
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  backend:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
          cache-dependency-path: backend/requirements-dev.txt
      - run: sudo apt-get update && sudo apt-get install -y ffmpeg
        working-directory: .
      - run: pip install -r requirements-dev.txt
      - run: pytest -q

  frontend:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: frontend/package-lock.json
      - run: npm ci
      - run: npm run build
      - run: npm test
EOF

# ------------------------------------------------------------------ README
echo "[*] Updating README.md"
python3 - "$ROOT/README.md" <<'PY'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("    README.md not found, skipping")
    sys.exit(0)
text = path.read_text()

def replace_once(old, new):
    global text
    if old in text:
        text = text.replace(old, new, 1)

# CI badge + screenshot placeholder under the title
if "actions/workflows/ci.yml" not in text:
    badge = (
        "[![CI](https://github.com/abderrahimlouay/yt-cutter/actions/workflows/ci.yml/badge.svg)]"
        "(https://github.com/abderrahimlouay/yt-cutter/actions/workflows/ci.yml)\n\n"
        "<!-- Add a screenshot or GIF: ![yt-cutter screenshot](docs/screenshot.png) -->\n\n"
    )
    replace_once("# yt-cutter\n\n", "# yt-cutter\n\n" + badge)

# requirements line
replace_once(
    "Requirements: Python 3.10+, Node 18+, ffmpeg on your PATH.",
    "Requirements: Python 3.10+, Node 22+ (builds the frontend and is the JavaScript runtime yt-dlp "
    "needs for YouTube), and ffmpeg on your PATH.",
)

# config table rows (each inserted only once)
def add_row(before_marker, rows):
    global text
    for row in rows:
        key = row.split("|")[1]
        if key not in text:
            replace_once(before_marker, row + "\n" + before_marker)

add_row("| `CLIPS_DIR` |", [
    "| `ALLOWED_HOSTS` | `[\"localhost\",\"127.0.0.1\"]` | Accepted `Host` headers (blocks DNS rebinding) |",
])
add_row("| `MAX_VIDEO_SECONDS` |", [
    "| `JS_RUNTIME` | `node` | JavaScript runtime for yt-dlp: `node`, `deno`, `bun` or `quickjs` |",
])
add_row("| `FILE_TTL_SECONDS` |", [
    "| `MAX_PENDING_JOBS` | `10` | Queued + running jobs before new ones get a 429 |",
    "| `JOB_TIMEOUT_SECONDS` | `900` | Cancel a job that runs longer than this |",
])

# Docker + troubleshooting sections
if "## Run with Docker" not in text:
    docker = """## Run with Docker

```bash
docker compose up --build
```

Open http://localhost:8080. Only the frontend port is published, and only on `127.0.0.1`; the backend is
reachable inside the compose network only. Clips are stored in memory-backed storage and vanish when the
container stops. To reach the app through another hostname or IP, add it to `YTCUTTER_ALLOWED_HOSTS`
in `docker-compose.yml`. YouTube changes often, so rebuild now and then to get a fresh yt-dlp:
`docker compose build --no-cache backend`.

"""
    replace_once("## Configuration\n", docker + "## Configuration\n")

if "## Troubleshooting" not in text:
    trouble = """## Troubleshooting

- **Downloads fail or formats are missing:** update yt-dlp with `pip install -U "yt-dlp[default]"`. The
  `default` extra includes `yt-dlp-ejs`, which YouTube extraction needs.
- **Server refuses to start, JavaScript runtime not found:** install Node 22+ (or Deno 2.3+), or set
  `YTCUTTER_JS_RUNTIME` to the runtime you have.
- **`Missing required binaries`:** install ffmpeg (`sudo apt install ffmpeg`).
- **400 Bad Request from the API:** the `Host` header is not in `YTCUTTER_ALLOWED_HOSTS`.

"""
    replace_once("## Disclaimer\n", trouble + "## Disclaimer\n")

# roadmap
start = text.find("## Roadmap")
end = text.find("## Troubleshooting") if "## Troubleshooting" in text else text.find("## Disclaimer")
if start != -1 and end != -1 and start < end:
    roadmap = """## Roadmap

- [x] Project scaffold
- [x] Backend: `/info` and `/cut`
- [x] Job system, SSE progress, cleanup
- [x] Frontend UI
- [ ] Docker setup (verified with `docker compose up --build`)
- [ ] Screenshots / demo GIF

"""
    text = text[:start] + roadmap + text[end:]

path.write_text(text)
PY

echo "[+] Done."
echo "    Try it:  docker compose up --build   ->  http://localhost:8080"
echo "    Then tick the Docker and screenshots items in README.md"
