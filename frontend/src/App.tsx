import { FormEvent, useEffect, useMemo, useState } from "react";

type JobStatus = "PENDING" | "PROCESSING" | "COMPLETED";

interface JobResponse {
  jobId: string;
  status: JobStatus;
  message: string;
  createdAt: string;
  updatedAt: string;
  processingAt?: string;
  processedAt?: string;
  result?: string;
}

type RuntimeMode = "AWS_DYNAMODB_SQS" | "LOCAL_MEMORY";

const apiBaseUrl = (import.meta.env.VITE_API_BASE_URL ?? "").replace(/\/$/, "");

async function createJob(message: string): Promise<{ jobId: string; status: JobStatus }> {
  const response = await fetch(`${apiBaseUrl}/jobs`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ message })
  });

  if (!response.ok) {
    throw new Error(`Create job failed with status ${response.status}`);
  }

  return (await response.json()) as { jobId: string; status: JobStatus };
}

async function fetchJob(jobId: string): Promise<JobResponse> {
  const response = await fetch(`${apiBaseUrl}/jobs/${jobId}`);

  if (!response.ok) {
    throw new Error(`Fetch job failed with status ${response.status}`);
  }

  return (await response.json()) as JobResponse;
}

async function fetchMode(): Promise<RuntimeMode> {
  const response = await fetch(`${apiBaseUrl}/jobs/mode`);
  if (!response.ok) {
    throw new Error(`Fetch mode failed with status ${response.status}`);
  }
  const payload = (await response.json()) as { mode: RuntimeMode };
  return payload.mode;
}

export default function App() {
  const [message, setMessage] = useState("Build me a Spring Boot sample");
  const [currentJobId, setCurrentJobId] = useState<string | null>(null);
  const [job, setJob] = useState<JobResponse | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mode, setMode] = useState<RuntimeMode | null>(null);

  const isConfigured = useMemo(() => Boolean(apiBaseUrl), []);

  function formatTimestampWithMs(iso?: string): string {
    if (!iso) {
      return "-";
    }

    const date = new Date(iso);
    const month = String(date.getMonth() + 1).padStart(2, "0");
    const day = String(date.getDate()).padStart(2, "0");
    const year = String(date.getFullYear());
    const hours24 = date.getHours();
    const hours12 = hours24 % 12 || 12;
    const minutes = String(date.getMinutes()).padStart(2, "0");
    const seconds = String(date.getSeconds()).padStart(2, "0");
    const ms = String(date.getMilliseconds()).padStart(3, "0");
    const period = hours24 >= 12 ? "pm" : "am";

    return `${month}/${day}/${year} ${hours12}:${minutes}:${seconds}.${ms} ${period}`;
  }

  useEffect(() => {
    if (!isConfigured) {
      return;
    }

    let cancelled = false;
    fetchMode()
      .then((runtimeMode) => {
        if (!cancelled) {
          setMode(runtimeMode);
        }
      })
      .catch((modeError) => {
        if (!cancelled) {
          setError((modeError as Error).message);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [isConfigured]);

  useEffect(() => {
    if (!currentJobId) {
      return;
    }

    let cancelled = false;
    const pollInterval = window.setInterval(async () => {
      try {
        const data = await fetchJob(currentJobId);
        if (!cancelled) {
          setJob(data);
          if (data.status === "COMPLETED") {
            window.clearInterval(pollInterval);
          }
        }
      } catch (pollError) {
        if (!cancelled) {
          setError((pollError as Error).message);
        }
      }
    }, 2000);

    return () => {
      cancelled = true;
      window.clearInterval(pollInterval);
    };
  }, [currentJobId]);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!isConfigured) {
      setError("Set VITE_API_BASE_URL before submitting jobs");
      return;
    }

    setError(null);
    setIsSubmitting(true);
    setJob(null);

    try {
      const created = await createJob(message.trim());
      setCurrentJobId(created.jobId);
      const initialJob = await fetchJob(created.jobId);
      setJob(initialJob);
    } catch (submitError) {
      setError((submitError as Error).message);
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <div className="page">
      <main className="card">
        <h1>Spring Boot Job Runner</h1>
        <p>
          Submit work from React to Spring Boot on AWS Fargate with DynamoDB + SQS-backed async state updates.
        </p>
        {mode && <p><strong>Backend mode:</strong> {mode}</p>}

        <form onSubmit={onSubmit} className="stack">
          <label htmlFor="message">Message</label>
          <input
            id="message"
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            placeholder="Type work payload"
            required
          />
          <button type="submit" disabled={isSubmitting || !message.trim()}>
            {isSubmitting ? "Submitting..." : "Create Job"}
          </button>
        </form>

        {!isConfigured && (
          <p className="warning">VITE_API_BASE_URL is missing. Add it in frontend/.env.local.</p>
        )}

        {error && <p className="error">{error}</p>}

        {job && (
          <section className="job">
            <h2>Job Status</h2>
            <p>
              <strong>ID:</strong> {job.jobId}
            </p>
            <p>
              <strong>Status pending:</strong> {formatTimestampWithMs(job.createdAt)}
            </p>
            <p>
              <strong>Status processing:</strong>{" "}
              {formatTimestampWithMs(job.processingAt)}
            </p>
            <p>
              <strong>Status completed:</strong>{" "}
              {formatTimestampWithMs(job.processedAt)}
            </p>
            <p>
              <strong>Message:</strong> {job.message}
            </p>
            {job.result && (
              <p>
                <strong>Result:</strong> {job.result}
              </p>
            )}
            <p>
              <strong>Updated:</strong> {new Date(job.updatedAt).toLocaleString()}
            </p>
          </section>
        )}
      </main>
    </div>
  );
}
