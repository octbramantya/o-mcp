// A button that opens the file chooser, on React Aria's FileTrigger (design/frontend-aria.md). The
// hidden file input sits inside `.file-button` beside the button, for anything that sets files on it.
import type { ReactNode } from 'react';
import { Button, FileTrigger } from 'react-aria-components';
import { Titled } from './toggles';

export function FileButton({ accept, onFile, title, children }: {
  /** MIME types and extensions, as the input's `accept`. */
  accept: string[];
  onFile: (f: File | undefined) => void;
  title?: string;
  children: ReactNode;
}) {
  return (
    <Titled title={title}>
      <span className="file-button">
        <FileTrigger acceptedFileTypes={accept} onSelect={(files) => onFile(files?.[0])}>
          <Button className="file-button-trigger">{children}</Button>
        </FileTrigger>
      </span>
    </Titled>
  );
}
