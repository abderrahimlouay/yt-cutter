import type { CutRequest, JobEvent, VideoInfo } from "../types";

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : "Something went wrong";
}

async function readError(res: Response): Promise<string> {
  try {
    const body = await res.json();
    if (typeof body?.detail === "string") return body.detail;
    if (typeof body?.error === "string" && !body.error.startsWith("Rate limit")) return body.error;
  } catch {
    // body was not JSON
  }
  if (res.status === 429) return "Too many requests, please wait a minute and try again.";
  if (res.status === 422) return "Invalid input.";
  return `Request failed (${res.status})`;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, init);
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") throw error;
    throw new ApiError("Cannot reach the server. Is the backend running?", 0);
  }
  if (!res.ok) throw new ApiError(await readError(res), res.status);
  return (await res.json()) as T;
}

function postJson<T>(path: string, body: unknown, signal?: AbortSignal): Promise<T> {
  return request<T>(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
}

export const fetchInfo = (url: string, signal?: AbortSignal) =>
  postJson<VideoInfo>("/api/info", { url }, signal);

export const startCut = (req: CutRequest) =>
  postJson<{ job_id: string }>("/api/cut", req);

export const getJob = (jobId: string) =>
  request<JobEvent>(`/api/jobs/${encodeURIComponent(jobId)}`);

export const jobEventsUrl = (jobId: string) =>
  `/api/jobs/${encodeURIComponent(jobId)}/events`;

export const jobDownloadUrl = (jobId: string) =>
  `/api/jobs/${encodeURIComponent(jobId)}/download`;
