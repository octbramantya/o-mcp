import { MutationCache, QueryCache, QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { ApiError } from './api/client';
import { App } from './App';
import './styles.css';

// A 401 anywhere means the session ended (expired, idle, or revoked by a reset): back to log-in.
const ended = (e: unknown) => {
  if (e instanceof ApiError && e.status === 401) client.setQueryData(['me'], null);
};
const client: QueryClient = new QueryClient({
  queryCache: new QueryCache({ onError: (e, q) => { if (q.queryKey[0] !== 'me') ended(e); } }),
  mutationCache: new MutationCache({ onError: (e, _v, _c, m) => { if (m.options.mutationKey?.[0] !== 'login') ended(e); } }),
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      retry: (n, e) => !(e instanceof ApiError && e.status < 500) && n < 2,
    },
  },
});

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={client}>
      <App />
    </QueryClientProvider>
  </StrictMode>,
);
