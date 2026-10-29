#!/usr/bin/env bash
# setup.sh - scaffolds the yt-cutter project, installs dependencies, prepares git.
# Usage: bash setup.sh
set -euo pipefail

PROJECT_DIR="yt-cutter"
REPO_URL="https://github.com/abderrahimlouay/yt-cutter.git"

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
info "Checking prerequisites"
missing=0
for cmd in git python3 node npm ffmpeg; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "missing: $cmd"
    missing=1
  fi
done
if [ "$missing" -eq 1 ]; then
  die "Install the missing tools first (Debian/Ubuntu: sudo apt install git python3 python3-venv nodejs npm ffmpeg)"
fi
python3 -m venv --help >/dev/null 2>&1 || die "python3-venv is missing (sudo apt install python3-venv)"
ok "git, python3, node, npm, ffmpeg found"

if [ -e "$PROJECT_DIR" ] && [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then
  die "'$PROJECT_DIR' already exists and is not empty. Remove it or run from another folder."
fi

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# ---------------------------------------------------------------- helpers
py_stub() {  # py_stub <path> <description>
  mkdir -p "$(dirname "$1")"
  printf '"""%s"""\n' "$2" > "$1"
}

tsx_stub() {  # tsx_stub <Name> <description>
  cat > "frontend/src/components/$1.tsx" <<EOF
// TODO: $1 - $2
export default function $1() {
  return null;
}
EOF
}

# ---------------------------------------------------------------- directories
info "Creating directory structure"
mkdir -p backend/app/{api,core,services} backend/tests
mkdir -p frontend/src/{components,hooks,lib}
mkdir -p docs

# ---------------------------------------------------------------- root files
info "Writing root files"

cat > .gitignore <<'EOF'
# Python
__pycache__/
*.py[cod]
.venv/
.pytest_cache/
.ruff_cache/
.mypy_cache/

# Node
node_modules/
dist/
*.tsbuildinfo

# Env / secrets
.env
*.local

# Runtime output
clips/
*.mp4
*.mp3
*.part
*.ytdl

# OS / editors
.DS_Store
.idea/
.vscode/
EOF

cat > LICENSE <<'EOF'
MIT License

Copyright (c) 2026 abderrahimlouay

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

cat > docker-compose.yml <<'EOF'
# TODO (milestone 5): backend (python + ffmpeg) and frontend services
EOF

cat > docs/architecture.md <<'EOF'
# Architecture

See the diagram and module responsibilities in the root README.md.
EOF

cat > README.md <<'EOF'
# yt-cutter

Local-first YouTube clip cutter. Paste a link, pick a start and end time, choose MP4 or MP3, and download only the segment you need.

**Stack:** FastAPI, yt-dlp, ffmpeg, React, TypeScript, Vite, Server-Sent Events.

## Features

- Paste a YouTube URL and get title, duration and thumbnail (metadata only, nothing downloaded)
- Embedded player preview with a dual-handle range slider and synced `mm:ss` inputs
- Cuts only the requested section (`yt-dlp --download-sections`), not the whole video
- MP4 or MP3 output, with a fast mode (stream copy) and an accurate mode (re-encode)
- Live progress over SSE, then a download button
- Hardened for local use: rate limiting, strict URL allowlist, length caps, concurrency limit, safe subprocess calls, automatic file cleanup

## Architecture

```
React (Vite, TS)  <--REST + SSE-->  FastAPI  -->  yt-dlp (fetch section)  -->  ffmpeg (cut/encode)  -->  temp clips dir
```

```
yt-cutter/
├── backend/
│   ├── app/
│   │   ├── main.py            # app factory, CORS, middleware, router mounting
│   │   ├── config.py          # settings loaded from .env
│   │   ├── api/
│   │   │   ├── routes.py      # /info, /cut, /jobs/{id}, /events, /download
│   │   │   └── schemas.py     # pydantic request/response models
│   │   ├── core/
│   │   │   ├── security.py    # URL allowlist, input validation, filename sanitising
│   │   │   └── rate_limit.py  # slowapi limiter
│   │   └── services/
│   │       ├── ytdlp.py       # metadata + section download (async subprocess)
│   │       ├── ffmpeg.py      # cut / re-encode / audio extraction
│   │       ├── jobs.py        # job store, states, progress, semaphore
│   │       └── cleanup.py     # periodic deletion of expired files
│   ├── tests/
│   ├── requirements.txt
│   └── .env.example
├── frontend/
│   └── src/
│       ├── components/        # UrlForm, VideoPreview, RangeSlider, FormatPicker, ProgressBar, DownloadButton
│       ├── hooks/             # useVideoInfo, useJob (EventSource)
│       ├── lib/               # api client, time helpers
│       └── types.ts
├── docs/
├── docker-compose.yml
└── README.md
```

### Request flow

1. `POST /api/info` validates the URL and returns video metadata.
2. `POST /api/cut` validates start/end/format, creates a job and returns `job_id`.
3. A background task acquires the concurrency semaphore, runs yt-dlp for the section, then ffmpeg if needed.
4. `GET /api/jobs/{id}/events` streams progress (SSE) until `done` or `error`.
5. `GET /api/jobs/{id}/download` serves the file; the cleanup task deletes it after the TTL.

### Job states

`queued -> downloading -> processing -> done | error`

## API

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/health` | Health check |
| POST | `/api/info` | Video metadata |
| POST | `/api/cut` | Start a cut job |
| GET | `/api/jobs/{id}` | Job status |
| GET | `/api/jobs/{id}/events` | SSE progress stream |
| GET | `/api/jobs/{id}/download` | Download the result |

## Security

- Only `youtube.com`, `www.youtube.com`, `m.youtube.com` and `youtu.be` URLs are accepted
- Subprocesses are started with argument lists, never `shell=True`
- Per-IP rate limits on `/info` and `/cut` (slowapi)
- Maximum source video duration and maximum clip length
- Concurrency limit on running jobs
- Sanitised output filenames, files stored in a dedicated temp directory
- Expired clips are deleted automatically
- CORS restricted to the configured frontend origin

## Getting started

Requirements: Python 3.10+, Node 18+, ffmpeg on your PATH.

```bash
# backend
cd backend
source .venv/bin/activate
cp .env.example .env
uvicorn app.main:app --reload --port 8000

# frontend (second terminal)
cd frontend
npm run dev
```

Open http://localhost:5173.

## Configuration

Set in `backend/.env` (prefix `YTCUTTER_`):

| Variable | Default | Description |
|----------|---------|-------------|
| `CORS_ORIGINS` | `["http://localhost:5173"]` | Allowed frontend origins |
| `CLIPS_DIR` | `/tmp/yt-cutter` | Where clips are written |
| `MAX_VIDEO_SECONDS` | `10800` | Reject longer source videos |
| `MAX_CLIP_SECONDS` | `600` | Reject longer clips |
| `MAX_CONCURRENT_JOBS` | `2` | Parallel jobs |
| `FILE_TTL_SECONDS` | `1800` | Time before clips are deleted |
| `RATE_LIMIT_INFO` | `20/minute` | Limit for `/info` |
| `RATE_LIMIT_CUT` | `5/minute` | Limit for `/cut` |

## Roadmap

- [x] Project scaffold
- [ ] Backend: `/info` and `/cut`
- [ ] Job system, SSE progress, cleanup
- [ ] Frontend UI
- [ ] Docker setup, screenshots

## Disclaimer

For personal, local use. Downloading content from YouTube may violate its Terms of Service, and you are responsible for respecting copyright. Only cut content you have the right to use.

## License

MIT
EOF
ok "Root files written"

# ---------------------------------------------------------------- backend
info "Writing backend files"

cat > backend/requirements.txt <<'EOF'
fastapi>=0.110
uvicorn[standard]>=0.29
yt-dlp[default]
sse-starlette>=2.0
slowapi>=0.1.9
pydantic-settings>=2.2
EOF

cat > backend/requirements-dev.txt <<'EOF'
-r requirements.txt
pytest
httpx
ruff
EOF

cat > backend/.env.example <<'EOF'
YTCUTTER_CORS_ORIGINS=["http://localhost:5173"]
YTCUTTER_CLIPS_DIR=/tmp/yt-cutter
YTCUTTER_MAX_VIDEO_SECONDS=10800
YTCUTTER_MAX_CLIP_SECONDS=600
YTCUTTER_MAX_CONCURRENT_JOBS=2
YTCUTTER_FILE_TTL_SECONDS=1800
YTCUTTER_RATE_LIMIT_INFO=20/minute
YTCUTTER_RATE_LIMIT_CUT=5/minute
EOF

cat > backend/app/config.py <<'EOF'
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="YTCUTTER_", extra="ignore")

    cors_origins: list[str] = ["http://localhost:5173"]
    clips_dir: str = "/tmp/yt-cutter"
    max_video_seconds: int = 3 * 3600
    max_clip_seconds: int = 600
    max_concurrent_jobs: int = 2
    file_ttl_seconds: int = 1800
    rate_limit_info: str = "20/minute"
    rate_limit_cut: str = "5/minute"


settings = Settings()
EOF

cat > backend/app/main.py <<'EOF'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings

app = FastAPI(title="yt-cutter", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# TODO: mount api.routes router, rate limiter and cleanup task
EOF

py_stub backend/app/__init__.py "yt-cutter backend package."
py_stub backend/app/api/__init__.py "HTTP layer."
py_stub backend/app/core/__init__.py "Security and cross-cutting concerns."
py_stub backend/app/services/__init__.py "Business logic: yt-dlp, ffmpeg, jobs, cleanup."
py_stub backend/app/api/routes.py "TODO: /info, /cut, /jobs/{id}, /jobs/{id}/events, /jobs/{id}/download."
py_stub backend/app/api/schemas.py "TODO: pydantic models for requests and responses."
py_stub backend/app/core/security.py "TODO: URL allowlist, time validation, filename sanitising."
py_stub backend/app/core/rate_limit.py "TODO: slowapi limiter configuration."
py_stub backend/app/services/ytdlp.py "TODO: metadata fetch and section download via asyncio subprocess."
py_stub backend/app/services/ffmpeg.py "TODO: cut, re-encode and audio extraction."
py_stub backend/app/services/jobs.py "TODO: job store, states, progress events, concurrency semaphore."
py_stub backend/app/services/cleanup.py "TODO: periodic deletion of expired clips."

cat > backend/tests/test_health.py <<'EOF'
from fastapi.testclient import TestClient

from app.main import app


def test_health() -> None:
    client = TestClient(app)
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
EOF

info "Creating Python virtualenv and installing backend dependencies"
python3 -m venv backend/.venv
# shellcheck disable=SC1091
source backend/.venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r backend/requirements-dev.txt
deactivate
ok "Backend dependencies installed"

# ---------------------------------------------------------------- frontend
info "Writing frontend files"

cat > frontend/package.json <<'EOF'
{
  "name": "yt-cutter-frontend",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc --noEmit && vite build",
    "preview": "vite preview"
  }
}
EOF

cat > frontend/index.html <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>yt-cutter</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
EOF

cat > frontend/vite.config.ts <<'EOF'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://localhost:8000",
    },
  },
});
EOF

cat > frontend/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true
  },
  "include": ["src"]
}
EOF

cat > frontend/src/vite-env.d.ts <<'EOF'
/// <reference types="vite/client" />
EOF

cat > frontend/src/main.tsx <<'EOF'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
EOF

cat > frontend/src/App.tsx <<'EOF'
export default function App() {
  return (
    <main>
      <h1>yt-cutter</h1>
      <p>Scaffold ready. UI coming in milestone 3.</p>
    </main>
  );
}
EOF

cat > frontend/src/types.ts <<'EOF'
export type Format = "mp4" | "mp3";

export type JobStatus = "queued" | "downloading" | "processing" | "done" | "error";

export interface VideoInfo {
  title: string;
  duration: number;
  thumbnail: string;
}

export interface JobEvent {
  status: JobStatus;
  progress: number;
  message?: string;
}
EOF

cat > frontend/src/lib/api.ts <<'EOF'
// TODO: typed fetch wrappers for /api/info, /api/cut, /api/jobs/{id}
export {};
EOF

cat > frontend/src/lib/time.ts <<'EOF'
// TODO: parse and format mm:ss / hh:mm:ss
export {};
EOF

cat > frontend/src/hooks/useVideoInfo.ts <<'EOF'
// TODO: fetch video metadata for a URL
export {};
EOF

cat > frontend/src/hooks/useJob.ts <<'EOF'
// TODO: start a job and subscribe to its SSE stream (EventSource)
export {};
EOF

tsx_stub UrlForm "URL input and submit"
tsx_stub VideoPreview "YouTube iframe player preview"
tsx_stub RangeSlider "dual-handle range slider synced with mm:ss inputs"
tsx_stub FormatPicker "MP4 / MP3 and fast vs accurate mode"
tsx_stub ProgressBar "live job progress"
tsx_stub DownloadButton "download link when the job is done"

info "Installing frontend dependencies (npm)"
(
  cd frontend
  npm install --silent react react-dom
  npm install --silent --save-dev vite @vitejs/plugin-react typescript @types/react @types/react-dom
)
ok "Frontend dependencies installed"

# ---------------------------------------------------------------- git
info "Initialising git"
git init -q
git symbolic-ref HEAD refs/heads/main
git remote add origin "$REPO_URL"
git add -A
if git commit -q -m "chore: initial project scaffold"; then
  ok "Initial commit created"
else
  warn "Commit failed (set git user.name and user.email, then commit manually)"
fi

# ---------------------------------------------------------------- done
cat <<EOF

$(printf '\033[1;32m')Done.$(printf '\033[0m') Project created in ./$PROJECT_DIR

Verify the backend:
  cd $PROJECT_DIR/backend && source .venv/bin/activate
  pytest
  uvicorn app.main:app --reload --port 8000

Run the frontend (second terminal):
  cd $PROJECT_DIR/frontend && npm run dev

Push to GitHub:
  cd $PROJECT_DIR
  git push -u origin main

Optional: set repo description and topics (needs the GitHub CLI, 'gh auth login' first):
  gh repo edit abderrahimlouay/yt-cutter \\
    --description "Local-first YouTube clip cutter: FastAPI + yt-dlp + ffmpeg backend, React + TypeScript frontend, live progress over SSE, rate limiting and hardened inputs." \\
    --add-topic fastapi,react,typescript,vite,ffmpeg,yt-dlp,youtube,video-cutter,sse,rate-limiting,python

EOF
