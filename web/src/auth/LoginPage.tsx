// Log-in, and the password change an account must make first (design/frontend.md §2). Nobody signs
// up: a super admin creates accounts.
import { useMutation, useQueryClient } from '@tanstack/react-query';
import type { FormEvent } from 'react';
import { useState } from 'react';
import { post } from '../api/client';
import type { Me } from '../api/types';

export function LoginPage() {
  const qc = useQueryClient();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const login = useMutation({
    mutationFn: () => post<Me>('/api/login', { email, password }),
    onSuccess: (me) => qc.setQueryData(['me'], me),
  });
  const submit = (e: FormEvent) => { e.preventDefault(); login.mutate(); };
  return (
    <form className="card auth" onSubmit={submit}>
      <h2>Log in</h2>
      <label>Email <input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
      <label>Password <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
      {login.error && <div className="error">{login.error.message}</div>}
      <button type="submit" className="primary" disabled={login.isPending}>Log in</button>
    </form>
  );
}

export function PasswordPage({ forced, onDone }: { forced: boolean; onDone?: () => void }) {
  const qc = useQueryClient();
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [again, setAgain] = useState('');
  const change = useMutation({
    mutationFn: () => post<Me>('/api/password', { current_password: current, new_password: next }),
    onSuccess: (me) => { qc.setQueryData(['me'], me); onDone?.(); },
  });
  const submit = (e: FormEvent) => { e.preventDefault(); if (next === again) change.mutate(); };
  return (
    <form className="card auth" onSubmit={submit}>
      <h2>{forced ? 'Choose your own password' : 'Change your password'}</h2>
      {forced && <p className="muted">Your account has a temporary password. Choose your own to go on; other sessions end.</p>}
      <label>Current password <input type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} required /></label>
      <label>New password <input type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} required /></label>
      <label>New password again <input type="password" autoComplete="new-password" value={again} onChange={(e) => setAgain(e.target.value)} required /></label>
      {next && again && next !== again && <div className="error">The two new passwords differ.</div>}
      {change.error && <div className="error">{change.error.message}</div>}
      <button type="submit" className="primary" disabled={change.isPending || next !== again}>Change password</button>
    </form>
  );
}
