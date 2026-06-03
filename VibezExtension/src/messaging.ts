// Runtime messages for explicit commands (state itself flows through
// chrome.storage). Popup → SW for register/test; content → SW for
// dismiss + block impressions.

export type RuntimeMessage =
  | { kind: "register" } // (re)register this client with the backend now
  | { kind: "test-block" } // inject a fake event to preview the overlay
  | { kind: "dismiss" } // user dismissed the overlay → lift the current block
  | { kind: "impression"; domain: string }; // overlay shown on a listed site

export interface Ack {
  ok: boolean;
  error?: string;
}

/// Normalize an unknown thrown value to a human-readable string.
export function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export async function sendToBackground(msg: RuntimeMessage): Promise<Ack> {
  try {
    const res = (await chrome.runtime.sendMessage(msg)) as Ack | undefined;
    return res ?? { ok: true };
  } catch (e) {
    return { ok: false, error: errorMessage(e) };
  }
}
