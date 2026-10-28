import { useCallback, useEffect, useRef, useState } from "react";
import { jobEventsUrl, messageOf, startCut } from "../lib/api";
import type { CutRequest, JobEvent, JobStatus } from "../types";

export type JobState =
  | { phase: "idle" }
  | { phase: "starting" }
  | { phase: "running"; jobId: string; status: JobStatus; progress: number }
  | { phase: "done"; jobId: string; filename: string | null }
  | { phase: "error"; message: string };

/** Starts a cut job and follows its progress over Server-Sent Events. */
export function useJob() {
  const [state, setState] = useState<JobState>({ phase: "idle" });
  const source = useRef<EventSource | null>(null);

  const close = useCallback(() => {
    source.current?.close();
    source.current = null;
  }, []);

  const start = useCallback(
    async (request: CutRequest) => {
      close();
      setState({ phase: "starting" });

      let jobId: string;
      try {
        jobId = (await startCut(request)).job_id;
      } catch (error) {
        setState({ phase: "error", message: messageOf(error) });
        return;
      }

      setState({ phase: "running", jobId, status: "queued", progress: 0 });
      const es = new EventSource(jobEventsUrl(jobId));
      source.current = es;

      es.onmessage = (msg) => {
        if (source.current !== es) return; // a newer job replaced this one
        let event: JobEvent;
        try {
          event = JSON.parse(msg.data) as JobEvent;
        } catch {
          return;
        }
        if (event.status === "done") {
          close();
          setState({ phase: "done", jobId, filename: event.filename });
        } else if (event.status === "error") {
          close();
          setState({ phase: "error", message: event.message ?? "The job failed" });
        } else {
          setState({ phase: "running", jobId, status: event.status, progress: event.progress });
        }
      };

      es.onerror = () => {
        if (source.current !== es) return;
        // CONNECTING means the browser is retrying; the server resends the current state on reconnect.
        if (es.readyState === EventSource.CLOSED) {
          close();
          setState({ phase: "error", message: "Lost connection to the server" });
        }
      };
    },
    [close],
  );

  const reset = useCallback(() => {
    close();
    setState({ phase: "idle" });
  }, [close]);

  useEffect(() => close, [close]);

  return { state, start, reset };
}
