// A question that needs an answer before going on, on React Aria's ModalOverlay, Modal and an alertdialog
// (design/frontend-aria.md), in place of window.confirm. `await confirm({...})` is true for the action and
// false for Cancel or Escape; a click outside doesn't answer. `ConfirmDialog` is the same dialog for a
// caller that holds the open state itself (the leave-page question, opened by the router's blocker).
// Focus starts on the action, or on Cancel when the action is destructive, and returns where it was.
import type { ReactNode } from 'react';
import { Button, Dialog, Heading, Modal, ModalOverlay } from 'react-aria-components';
import { create } from 'zustand';

export interface Question {
  title: string;
  body?: ReactNode;
  /** The action button's label: a verb, never "OK". */
  action: string;
  cancel?: string;
  /** Deletes or discards something: the action in the danger colour, and focus on Cancel. */
  danger?: boolean;
}

export function ConfirmDialog({ isOpen, onAnswer, title, body, action, cancel = 'Cancel', danger }: Question & {
  isOpen: boolean;
  onAnswer: (yes: boolean) => void;
}) {
  return (
    <ModalOverlay className="modal-overlay" isOpen={isOpen} onOpenChange={(o) => { if (!o) onAnswer(false); }}>
      <Modal className="popover-surface modal">
        <Dialog role="alertdialog" className="confirm">
          <Heading slot="title" className="confirm-title">{title}</Heading>
          {body && <div className="confirm-body">{body}</div>}
          <div className="confirm-actions">
            <Button autoFocus={danger} onPress={() => onAnswer(false)}>{cancel}</Button>
            <Button autoFocus={!danger} className={danger ? 'danger' : 'primary'} onPress={() => onAnswer(true)}>{action}</Button>
          </div>
        </Dialog>
      </Modal>
    </ModalOverlay>
  );
}

// One question at a time: asking while one is open answers the first with false.
const useAsked = create<{ q: Question | null; answer: (yes: boolean) => void }>(() => ({ q: null, answer: () => {} }));

export function confirm(q: Question): Promise<boolean> {
  useAsked.getState().answer(false);
  return new Promise((resolve) => {
    useAsked.setState({
      q,
      answer: (yes) => { useAsked.setState({ q: null, answer: () => {} }); resolve(yes); },
    });
  });
}

/** Mounted once, beside the app: where `confirm` asks. */
export function ConfirmHost() {
  const { q, answer } = useAsked();
  return q ? <ConfirmDialog isOpen {...q} onAnswer={answer} /> : null;
}
