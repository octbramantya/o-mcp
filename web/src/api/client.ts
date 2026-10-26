// The API on the same origin (vite.config.ts forwards /api in development). Every error comes back
// as {error, message}; the message is for the person and is shown as is.
export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

async function request<T>(method: 'GET' | 'POST', path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
  const res = await fetch(path, {
    method,
    signal,
    credentials: 'same-origin',
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    throw new ApiError(res.status, data?.error ?? 'failed', data?.message ?? `The request failed (${res.status}).`);
  }
  return data as T;
}

type Params = Record<string, string | number | boolean | null | undefined>;

export function get<T>(path: string, params?: Params, signal?: AbortSignal): Promise<T> {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params ?? {})) {
    if (v !== null && v !== undefined && v !== '') q.set(k, String(v));
  }
  const s = q.toString();
  return request<T>('GET', s ? `${path}?${s}` : path, undefined, signal);
}

export function post<T>(path: string, body: unknown = {}): Promise<T> {
  return request<T>('POST', path, body);
}
