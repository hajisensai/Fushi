// Fushi Lens frontend (Steam UI side).
//
// - Quick Access panel: pair with a Fushi app (address + PIN), pick the back
//   button, capture now.
// - A full-screen Steam route that embeds the Lens page served by the plugin
//   backend on 127.0.0.1, and forwards controller buttons to it.
//
// Flow: back button -> backend grabs the game frame (before any Steam UI is on
// screen) -> emits `fushi_lens_frame` -> this opens the route on that frame.
import {
  ButtonItem,
  DropdownItem,
  Focusable,
  GamepadButton,
  GamepadEvent,
  Navigation,
  PanelSection,
  PanelSectionRow,
  TextField,
  staticClasses,
} from "@decky/ui";
import { addEventListener, callable, definePlugin, removeEventListener, routerHook, toaster } from "@decky/api";
import { useEffect, useRef, useState } from "react";

const ROUTE = "/fushi-lens";
const BUTTONS = ["L4", "R4", "L5", "R5"];

type Status = {
  paired: boolean;
  host: string | null;
  pairing: boolean;
  lensUrl: string | null;
  button: string;
  buttonError: string | null;
};
type Result = { ok: boolean; error?: string; detail?: string };
type FrameInfo = { frameId: string; width: number; height: number };

const getStatus = callable<[], Status>("status");
const beginPairing = callable<[string], Result & { pinRequired?: boolean; fingerprint?: string }>("begin_pairing");
const finishPairing = callable<[string], Result>("finish_pairing");
const unpair = callable<[], Result>("unpair");
const captureNow = callable<[], Result & Partial<FrameInfo>>("capture");
const setButton = callable<[string], Result>("set_button");

const ERRORS: Record<string, string> = {
  unreachable: "Can't reach Fushi at that address. Is it running with Interconnect on?",
  pin: "Wrong PIN.",
  declined: "Pairing was declined in Fushi.",
  rate_limited: "Too many attempts. Wait a minute.",
  unavailable: "Pairing is turned off in Fushi.",
  tls: "Certificate check failed. Pair again.",
  capture: "Screen capture failed.",
  lens_consent: "Allow Google Lens in Fushi on your PC, then try again.",
  engine_failed: "Google Lens failed. Check your PC's internet connection.",
  address: "That address doesn't look right.",
};
const errorText = (r: Result) => ERRORS[r.error ?? ""] ?? `Error: ${r.error}${r.detail ? ` (${r.detail})` : ""}`;

let lensUrl: string | null = null;
let pendingFrame: string | null = null;
let postToLens: ((msg: unknown) => void) | null = null;

function openLens(frameId: string) {
  pendingFrame = frameId;
  if (postToLens) {
    postToLens({ fushiLens: "frame", frameId });
    return;
  }
  Navigation.CloseSideMenus();
  Navigation.Navigate(ROUTE);
}

// ── Lens route ──────────────────────────────────────────────────────────

const BUTTON_NAMES: Partial<Record<GamepadButton, string>> = {
  [GamepadButton.DIR_UP]: "UP",
  [GamepadButton.DIR_DOWN]: "DOWN",
  [GamepadButton.DIR_LEFT]: "LEFT",
  [GamepadButton.DIR_RIGHT]: "RIGHT",
  [GamepadButton.OK]: "A",
  [GamepadButton.CANCEL]: "B",
  [GamepadButton.SECONDARY]: "X",
  [GamepadButton.OPTIONS]: "Y",
  [GamepadButton.BUMPER_LEFT]: "LB",
  [GamepadButton.BUMPER_RIGHT]: "RB",
};

function LensRoute() {
  const frame = useRef<HTMLIFrameElement>(null);
  const [src] = useState(() => (lensUrl ? `${lensUrl}#frame=${pendingFrame ?? ""}` : null));

  useEffect(() => {
    const origin = lensUrl ? new URL(lensUrl).origin : "";
    postToLens = (msg) => frame.current?.contentWindow?.postMessage(msg, origin);
    const onMessage = (e: MessageEvent) => {
      if (e.source === frame.current?.contentWindow && e.data?.fushiLens === "exit") Navigation.NavigateBack();
    };
    window.addEventListener("message", onMessage);
    return () => {
      postToLens = null;
      window.removeEventListener("message", onMessage);
    };
  }, []);

  const onButton = (evt: GamepadEvent) => {
    const button = evt.detail.button;
    // The capture button again (or Steam's back paddles) closes the Lens.
    if (button >= GamepadButton.REAR_LEFT_UPPER && button <= GamepadButton.REAR_RIGHT_LOWER) {
      Navigation.NavigateBack();
      return;
    }
    const name = BUTTON_NAMES[button];
    if (name) postToLens?.({ fushiLens: "button", button: name });
  };

  if (!src) {
    return <div style={{ padding: "60px 24px" }}>Fushi Lens is not running. Reload the plugin.</div>;
  }
  return (
    <Focusable
      style={{ position: "fixed", inset: 0, zIndex: 7000, background: "#000" }}
      onActivate={() => {}}
      onButtonDown={onButton}
      onCancelButton={() => {}}
      noFocusRing
    >
      <iframe
        ref={frame}
        src={src}
        style={{ width: "100%", height: "100%", border: 0, display: "block" }}
        title="Fushi Lens"
      />
    </Focusable>
  );
}

// ── Quick Access panel ─────────────────────────────────────────────────

function Panel() {
  const [status, setStatus] = useState<Status | null>(null);
  const [address, setAddress] = useState("");
  const [pin, setPin] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const refresh = async () => {
    const s = await getStatus();
    lensUrl = s.lensUrl;
    setStatus(s);
  };
  useEffect(() => {
    refresh();
  }, []);

  const run = async (fn: () => Promise<Result>, done?: string) => {
    setBusy(true);
    setMessage(null);
    try {
      const r = await fn();
      setMessage(r.ok ? done ?? null : errorText(r));
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  if (!status) return <PanelSection>Loading…</PanelSection>;
  return (
    <>
      <PanelSection title="Fushi">
        {status.paired ? (
          <>
            <PanelSectionRow>
              <div>Paired with {status.host}</div>
            </PanelSectionRow>
            <PanelSectionRow>
              <ButtonItem
                layout="below"
                disabled={busy}
                onClick={async () => {
                  Navigation.CloseSideMenus();
                  // Let the menu slide away so it isn't in the captured frame.
                  await new Promise((r) => setTimeout(r, 450));
                  const r = await captureNow();
                  if (r.ok && r.frameId) openLens(r.frameId);
                  else toaster.toast({ title: "Fushi Lens", body: errorText(r) });
                }}
              >
                Read the screen now
              </ButtonItem>
            </PanelSectionRow>
            <PanelSectionRow>
              <ButtonItem layout="below" disabled={busy} onClick={() => run(unpair, "Unpaired.")}>
                Unpair
              </ButtonItem>
            </PanelSectionRow>
          </>
        ) : status.pairing ? (
          <>
            <PanelSectionRow>
              <TextField label="PIN shown in Fushi" value={pin} onChange={(e) => setPin(e.target.value)} />
            </PanelSectionRow>
            <PanelSectionRow>
              <ButtonItem layout="below" disabled={busy} onClick={() => run(() => finishPairing(pin), "Paired.")}>
                Confirm
              </ButtonItem>
            </PanelSectionRow>
          </>
        ) : (
          <>
            <PanelSectionRow>
              <TextField
                label="Fushi address (PC IP)"
                description="In Fushi: Settings → Interconnect"
                value={address}
                onChange={(e) => setAddress(e.target.value)}
              />
            </PanelSectionRow>
            <PanelSectionRow>
              <ButtonItem
                layout="below"
                disabled={busy || !address.trim()}
                onClick={() => run(() => beginPairing(address), "Enter the PIN Fushi shows and approve the device.")}
              >
                Pair
              </ButtonItem>
            </PanelSectionRow>
          </>
        )}
        {message && (
          <PanelSectionRow>
            <div style={{ fontSize: "12px", opacity: 0.85 }}>{message}</div>
          </PanelSectionRow>
        )}
      </PanelSection>
      <PanelSection title="Controls">
        <PanelSectionRow>
          <DropdownItem
            label="Read-screen button"
            rgOptions={BUTTONS.map((b) => ({ data: b, label: b }))}
            selectedOption={status.button}
            onChange={(o) => run(() => setButton(String(o.data)))}
          />
        </PanelSectionRow>
        {status.buttonError && (
          <PanelSectionRow>
            <div style={{ fontSize: "12px", opacity: 0.85 }}>Back buttons unavailable: {status.buttonError}</div>
          </PanelSectionRow>
        )}
        <PanelSectionRow>
          <div style={{ fontSize: "12px", opacity: 0.7 }}>
            In the Lens: D-pad picks a line and a character, A looks up, X mines, B goes back. Set the button to
            “None” for the game in Steam Input so the game ignores it.
          </div>
        </PanelSectionRow>
      </PanelSection>
    </>
  );
}

function Icon() {
  return (
    <svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor" aria-hidden="true">
      <path d="M9.5 3a6.5 6.5 0 0 1 5.2 10.4l5.4 5.4-1.4 1.4-5.4-5.4A6.5 6.5 0 1 1 9.5 3zm0 2a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9zM7 8h5v1.5H7zm0 2.5h4V12H7z" />
    </svg>
  );
}

export default definePlugin(() => {
  routerHook.addRoute(ROUTE, LensRoute, { exact: true });
  getStatus().then((s) => (lensUrl = s.lensUrl));
  const onFrame = addEventListener<[FrameInfo]>("fushi_lens_frame", (info) => {
    if (!lensUrl) getStatus().then((s) => ((lensUrl = s.lensUrl), openLens(info.frameId)));
    else openLens(info.frameId);
  });
  const onError = addEventListener<[Result]>("fushi_lens_error", (r) =>
    toaster.toast({ title: "Fushi Lens", body: errorText(r) }),
  );
  return {
    name: "Fushi Lens",
    titleView: <div className={staticClasses.Title}>Fushi Lens</div>,
    content: <Panel />,
    icon: <Icon />,
    onDismount() {
      removeEventListener("fushi_lens_frame", onFrame);
      removeEventListener("fushi_lens_error", onError);
      routerHook.removeRoute(ROUTE);
    },
  };
});
