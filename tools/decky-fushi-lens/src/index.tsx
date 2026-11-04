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
  GamepadEvent,
  Navigation,
  PanelSection,
  PanelSectionRow,
  Router,
  TextField,
  ToggleField,
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
  touch: boolean;
  regions: Record<string, string>;
};
type Result = { ok: boolean; error?: string; detail?: string };
type FrameInfo = { frameId: string; width: number; height: number };

const getStatus = callable<[], Status>("status");
const beginPairing = callable<[string], Result & { pinRequired?: boolean; fingerprint?: string }>("begin_pairing");
const finishPairing = callable<[string], Result>("finish_pairing");
const unpair = callable<[], Result>("unpair");
const captureNow = callable<[], Result & Partial<FrameInfo>>("capture");
const setButton = callable<[string], Result>("set_button");
const setLensOpen = callable<[boolean], Result>("set_lens_open");
const setTouch = callable<[boolean], Result>("set_touch");
const setRegion = callable<[string, string | null], Result & { regions?: Record<string, string> }>("set_region");

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
let touchEnabled = false;
// Reading area per game ("x,y,w,h" in frame pixels), keyed by Steam appid.
let regions: Record<string, string> = {};

// The game in front ("0" outside a game, e.g. reading the Steam UI itself).
const currentApp = (): { id: string; name: string } => {
  const app = Router.MainRunningApp;
  return { id: String(app?.appid ?? "0"), name: app?.display_name ?? "" };
};

const remember = (s: Status) => {
  lensUrl = s.lensUrl;
  touchEnabled = s.touch;
  regions = s.regions ?? {};
};
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

// Steam's own controller button ids (`RegisterForControllerInputMessages`,
// enum read from Steam's steamui/sp.js on SteamOS 2026-11-04). Steam's focus
// navigation never hands these presses to a plugin route that only holds an
// iframe, so the route listens to the raw input stream while it is mounted.
const STEAM_BUTTONS: Record<number, string> = {
  0: "A",
  1: "B",
  2: "X",
  3: "Y",
  4: "UP",
  5: "RIGHT",
  6: "DOWN",
  7: "LEFT",
  20: "UP", // left stick
  21: "DOWN",
  22: "LEFT",
  23: "RIGHT",
  30: "LB",
  31: "RB",
};

const STEAM_BACK_BUTTONS = [32, 33, 44, 45];

type InputRegistration = { unregister(): void };
declare const SteamClient: {
  Input: {
    RegisterForControllerInputMessages(
      cb: (controller: number, button: number, pressed: boolean) => void,
    ): InputRegistration;
  };
};

// Steam's focus navigation acts on the same presses (the d-pad moved focus to
// the search bar). The Lens holds Steam focus on one element that consumes
// every navigation and face-button event; the actual handling comes from the
// raw input stream above.
const swallow = (evt: GamepadEvent) => {
  evt.preventDefault();
  evt.stopPropagation();
};

function LensRoute() {
  const frame = useRef<HTMLIFrameElement>(null);
  const trap = useRef<HTMLDivElement>(null);
  const [app] = useState(currentApp);
  const [src] = useState(() => {
    if (!lensUrl) return null;
    const hash = new URLSearchParams({ frame: pendingFrame ?? "" });
    if (touchEnabled) hash.set("touch", "1");
    const region = regions[app.id];
    if (region) hash.set("region", region);
    return `${lensUrl}#${hash}`;
  });

  useEffect(() => {
    const origin = lensUrl ? new URL(lensUrl).origin : "";
    postToLens = (msg) => frame.current?.contentWindow?.postMessage(msg, origin);
    let bFallback = 0;
    const onMessage = (e: MessageEvent) => {
      if (e.source !== frame.current?.contentWindow) return;
      if (e.data?.fushiLens === "ack") clearTimeout(bFallback);
      if (e.data?.fushiLens === "exit") Navigation.NavigateBack();
      if (e.data?.fushiLens === "region") {
        const region = typeof e.data.region === "string" ? e.data.region : null;
        void setRegion(app.id, region).then((r) => r.regions && (regions = r.regions));
      }
    };
    // The iframe lives in the Big Picture window, while this code runs in
    // SharedJSContext: the page's "exit" goes to the window that hosts it.
    const host = frame.current?.ownerDocument?.defaultView ?? window;
    host.addEventListener("message", onMessage);
    trap.current?.focus();
    void setLensOpen(true);
    const input = SteamClient.Input.RegisterForControllerInputMessages((_controller, button, pressed) => {
      if (!pressed) return;
      // Back buttons (L5 R5 L4 R4) close the Lens: the capture button toggles it.
      if (STEAM_BACK_BUTTONS.includes(button)) {
        Navigation.NavigateBack();
        return;
      }
      const name = STEAM_BUTTONS[button];
      if (!name) return;
      postToLens?.({ fushiLens: "button", button: name });
      if (name === "B") {
        // Safety net: if the page does not answer, B leaves the Lens anyway.
        clearTimeout(bFallback);
        bFallback = window.setTimeout(() => Navigation.NavigateBack(), 600);
      }
    });
    return () => {
      input.unregister();
      clearTimeout(bFallback);
      // Let the closing back-button press reach the backend first, so it does not
      // capture the Lens screen and reopen it.
      setTimeout(() => void setLensOpen(false), 400);
      postToLens = null;
      host.removeEventListener("message", onMessage);
    };
  }, []);

  if (!src) {
    return <div style={{ padding: "60px 24px" }}>Fushi Lens is not running. Reload the plugin.</div>;
  }
  return (
    <Focusable
      ref={trap}
      style={{ position: "fixed", inset: 0, zIndex: 7000, background: "#000" }}
      preferredFocus
      noFocusRing
      onActivate={() => {}}
      onGamepadDirection={swallow}
      onOKButton={swallow}
      onSecondaryButton={swallow}
      onOptionsButton={swallow}
      onCancelButton={swallow}
      // B too: the Lens closes its popup first and asks to leave only when none is open.
      onButtonDown={swallow}
      onGamepadBlur={() => setTimeout(() => trap.current?.focus(), 0)}
    >
      <iframe
        ref={frame}
        src={src}
        tabIndex={-1}
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
    remember(s);
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
  const app = currentApp();
  const appRegion = app.id !== "0" ? status.regions?.[app.id] : undefined;
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
        <PanelSectionRow>
          <ToggleField
            label="Tap to look up"
            description="Tap a character to look it up, tap outside the popup to close it"
            checked={status.touch}
            onChange={(on) => run(() => setTouch(on))}
          />
        </PanelSectionRow>
        {app.id !== "0" && (
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              disabled={busy || !appRegion}
              description={
                appRegion
                  ? `${app.name || "This game"}: reads only the saved area. Press Y in the Lens to change it.`
                  : `${app.name || "This game"}: reads the whole screen. Press Y in the Lens to read only the dialogue box.`
              }
              onClick={() => run(() => setRegion(app.id, null), "Reading the whole screen.")}
            >
              Read the whole screen
            </ButtonItem>
          </PanelSectionRow>
        )}
        {status.buttonError && (
          <PanelSectionRow>
            <div style={{ fontSize: "12px", opacity: 0.85 }}>Back buttons unavailable: {status.buttonError}</div>
          </PanelSectionRow>
        )}
        <PanelSectionRow>
          <div style={{ fontSize: "12px", opacity: 0.7 }}>
            In the Lens: D-pad picks a line and a character, A looks up, X mines, Y sets the reading area, B goes back. Set the button to
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
  getStatus().then(remember);
  const onFrame = addEventListener<[FrameInfo]>("fushi_lens_frame", (info) => {
    if (!lensUrl) getStatus().then((s) => (remember(s), openLens(info.frameId)));
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
