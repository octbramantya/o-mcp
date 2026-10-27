import { describe, expect, it } from 'vitest';
import { fmt } from './common';

describe('fmt', () => {
  it('shows 2 decimals with thousands separated, by default', () => {
    expect(fmt(1234567.891)).toBe('1,234,567.89');
    expect(fmt(0.5)).toBe('0.50');
    expect(fmt(-3)).toBe('-3.00');
  });
  it('takes other decimals when asked', () => {
    expect(fmt(1.23456, 3)).toBe('1.235');
  });
  it('shows a missing figure as a dash', () => {
    expect(fmt(null)).toBe('—');
    expect(fmt(undefined)).toBe('—');
    expect(fmt(Number.NaN)).toBe('—');
  });
});
