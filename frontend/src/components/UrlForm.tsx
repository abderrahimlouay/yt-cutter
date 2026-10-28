import { useState, type FormEvent } from "react";

interface Props {
  loading: boolean;
  error: string | null;
  onSubmit: (url: string) => void;
}

export default function UrlForm({ loading, error, onSubmit }: Props) {
  const [url, setUrl] = useState("");

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (url.trim()) onSubmit(url.trim());
  };

  return (
    <form onSubmit={submit}>
      <div className="row">
        <input
          type="text"
          inputMode="url"
          autoComplete="off"
          spellCheck={false}
          placeholder="Paste a YouTube link"
          aria-label="YouTube URL"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
        />
        <button className="button primary" type="submit" disabled={loading || !url.trim()}>
          {loading ? "Loading…" : "Load video"}
        </button>
      </div>
      {error && (
        <div className="error" role="alert">
          {error}
        </div>
      )}
    </form>
  );
}
