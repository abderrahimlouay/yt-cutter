// Keep in sync with YTCUTTER_MAX_CLIP_SECONDS on the backend (the server is the real enforcer).
// Override at build time with VITE_MAX_CLIP_SECONDS.
export const MAX_CLIP_SECONDS = Number(import.meta.env.VITE_MAX_CLIP_SECONDS ?? 600);
export const MIN_CLIP_SECONDS = 1;
export const DEFAULT_CLIP_SECONDS = 30;
