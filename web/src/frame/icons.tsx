// The Activity Bar's icons: 24 px line drawings in the text colour, so they follow the theme.
import type { ReactNode } from 'react';

function Icon({ children }: { children: ReactNode }) {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.6"
         strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

export const FindIcon = () => <Icon><circle cx="10.5" cy="10.5" r="6" /><path d="M15 15l5.5 5.5" /></Icon>;

export const CategoriesIcon = () => (
  <Icon>
    <rect x="3" y="3.5" width="7" height="5" rx="1" /><rect x="14" y="10" width="7" height="4.5" rx="1" />
    <rect x="14" y="16.5" width="7" height="4.5" rx="1" /><path d="M6.5 8.5v10h7.5M6.5 12.25h7.5" />
  </Icon>
);

export const StarIcon = () => <Icon><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z" /></Icon>;

export const ReferenceIcon = () => (
  <Icon>
    <path d="M5 5a2 2 0 0 1 2-2h12v15H7a2 2 0 0 0-2 2z" /><path d="M5 20a2 2 0 0 0 2 2h12v-4" />
    <path d="M12 7.5v.01M12 10.5v4" />
  </Icon>
);
