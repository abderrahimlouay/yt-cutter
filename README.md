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
