#!/usr/bin/env python3
"""
slzb-proxy v5 — TCP keep-alive proxy for SLZB-06MG24 with drain + timeout

Background: SLZB-OS 3.3.1 "reboot EFR32 at startup" wiped the EFR32's NVM.
EFR32 firmware 8.0.2 b397 has a bug where NVM token writes trigger
RESET_SOFTWARE at runtime ~7-8s after "Zigbee2MQTT started!". This is the
EmberZNet NVM save timer firing and writing configuration tokens to flash,
which causes a spontaneous EFR32 soft reset.

Root cause of crash loop:
  coordinator_backup.json frame_counter > EFR32's current frame counter after
  each crash-reset causes herdsman to restore the high counter via EZSP, which
  dirties an NVM token, which the NVM save timer writes 7-8s later →
  RESET_SOFTWARE → crash → repeat. Fix: keep coordinator_backup.json
  frame_counter=0 so herdsman never writes a frame counter to EFR32 (EFR32
  always has counter >= 0, so no write is needed).

What this proxy fixes (4 failure modes):

1. HOST_FATAL_ERROR on new connection — stale RSTACK data accumulates in
   the SLZB TCP receive buffer while Z2M is crashed. When Z2M reconnects,
   _slzb_to_client reads and forwards the stale RSTACK before Z2M has even
   sent RST, causing immediate HOST_FATAL_ERROR. Fix: drain (discard) data
   from the SLZB socket during the post-disconnect hold period (drain-only
   mode: SLZB TCP connection is kept alive; no cycling).

2. _slzb_to_client hangs forever — if Z2M crashes with ASH_ERROR_TIMEOUTS
   (adapter sent no data), _slzb_to_client is blocked on recv() with no
   data coming, so session.run() never returns and the hold/drain loop
   never starts. Fix: use select() with a timeout in _slzb_to_client so
   it can check _stop and exit promptly.

3. Stale-connection churn — during the drain period Z2M crashes and restarts
   multiple times. The OS queues these stale TCP connections in the backlog.
   When the drain ends and the proxy calls accept(), it gets a stale CLOSE_WAIT
   connection that immediately returns EOF, triggering another unnecessary drain
   cycle. Fix: track session duration; sessions < MIN_REAL_SESSION_DURATION are
   stale and skipped (no drain started).

4. Long-lived proxy process itself gets stuck — observed 2026-07-21: Z2M was
   crash-looping for 9+ minutes in a pattern that never tripped the
   MAX_CONSECUTIVE_STALE detector below (one stale session followed by one
   ~15s "real" session each cycle, which resets the stale counter before it
   reaches 3). The proxy's own reconnect()/drain() cycle kept running
   correctly the whole time (confirmed via its logs) but never once produced
   a working Z2M startup. `docker stop`/`start` on the zigbee2mqtt container
   alone did NOT fix it that time. Restarting the proxy *process* itself did,
   on the very next cycle.

   Neither alone is reliable every time — observed again 2026-07-22, a few
   hours later: proxy-only process restarts (the first version of this fix)
   fired repeatedly and correctly, but Z2M's restart:unless-stopped kept
   hammering reconnects the entire time, and the SLZB's own TCP listener on
   :6638 started refusing/timing out new connections for 60-70s stretches —
   the loop never actually cleared. Matches the documented incident history
   (module docstring): only a genuinely undisturbed window — Z2M making ZERO
   connection attempts, not just a fresh proxy socket — reliably lets the
   EFR32 settle. Fix: if no session has run long enough to count as
   genuinely stable for MAX_TIME_WITHOUT_STABLE_SESSION seconds despite
   ongoing cycling, do both together — `docker stop` zigbee2mqtt, hold for
   FORCE_RESTART_STOP_DURATION seconds while it's fully down, `docker start`
   it, then exit this process so launchd respawns it with fully fresh
   sockets/threads just as Z2M's fresh reconnect attempts arrive.

NOT an EFR32 firmware issue (corrected 2026-07-20, re-confirmed 2026-07-22):
  an earlier version of this docstring concluded the RESET_SOFTWARE/NVM-token
  bug above required an EFR32 coordinator firmware update. That recurred with
  firmware unchanged and was resolved without touching firmware both times —
  do not suggest a firmware update for this. The actual fix is a clean, fully
  -stopped recovery window: `docker stop zigbee2mqtt`, wait 45-60s with the
  container genuinely down (not crash-restarting), `docker start`. Docker's
  `restart: unless-stopped` reconnects near-instantly on crash with no
  backoff, and repeated rapid Z2M reconnect attempts never give the EFR32 an
  undisturbed window to settle — only a real stop guarantees one. This proxy
  now does replicate that automatically as of failure mode 4 above — stop
  Z2M outright rather than trying to out-clever it purely at the proxy layer.

Listen: 127.0.0.1:6639  →  SLZB: 10.100.20.158:6638 (k3s sidecar of the zigbee2mqtt pod)
"""

from __future__ import annotations

import os
import select
import socket
import threading
import time
import syslog
import sys

LISTEN_HOST          = "127.0.0.1"  # same pod as Z2M: loopback
LISTEN_PORT          = int(os.environ.get("PROXY_LISTEN_PORT", "6639"))
SLZB_HOST            = os.environ.get("SLZB_HOST", "10.100.20.158")
SLZB_PORT            = int(os.environ.get("SLZB_PORT", "6638"))
RECONNECT_DELAY      = 2    # seconds between SLZB reconnect attempts
# Total hold period after each real Z2M disconnect. With RECONNECT=True the
# breakdown is: 20s SLZB_RECONNECT_PAUSE (quiet period for EFR32 NVM loop to
# stabilise in isolation) + ~2s reconnect + ~23s drain = 45s total.
# Must be > SLZB_RECONNECT_PAUSE + EFR32 boot time (~5s) = ~27s.
POST_DISCONNECT_DELAY = 45  # seconds to drain/hold after each Z2M disconnect
# Minimum session duration to be considered a "real" Z2M connection. Sessions
# shorter than this are stale sockets (Z2M crashed before the proxy accepted them)
# and should not trigger a SLZB drain cycle.
MIN_REAL_SESSION_DURATION = 5.0  # seconds
# A tight Z2M crash loop (Docker restarts near-instantly, no backoff) produces
# a run of stale (<5s) sessions with zero cooldown between them today, which
# means the protective drain/pause cycle below — the thing that actually
# recovers the EFR32 from a bad state — never gets a chance to run. Observed
# 2026-07-20: proxy cycled correctly on every real (>=5s) session and Z2M
# still failed every time; only a fully-stopped Z2M (no reconnect attempts at
# all) for 45-60s let the coordinator recover. After this many consecutive
# stale sessions, force a full recovery cycle anyway to get the same effect
# without requiring a manual `docker stop`.
MAX_CONSECUTIVE_STALE = 3
# A session this long or longer means Z2M is genuinely up and running (real
# sessions just don't end on their own once zigbee-herdsman has actually
# started — something failing repeatedly at ~15-20s per attempt is still a
# failed startup, not recovery, even though it clears MIN_REAL_SESSION_DURATION).
STABLE_SESSION_DURATION = 60.0  # seconds
# If no session has reached STABLE_SESSION_DURATION within this window despite
# ongoing cycling, the proxy's own process state — not just Z2M/EFR32 — is the
# likely culprit (see failure mode 4 above). Exit and let launchd respawn us.
MAX_TIME_WITHOUT_STABLE_SESSION = 180.0  # seconds
# How long to hold zigbee2mqtt fully stopped — matches the documented manual
# recovery window (45-60s) that has reliably cleared this loop historically.
FORCE_RESTART_STOP_DURATION = 60.0  # seconds
SLZB_SELECT_TIMEOUT  = 1.0  # select() timeout in _slzb_to_client (lets _stop be checked)
# After each Z2M disconnect, close and reconnect the SLZB TCP connection.
# The 20s quiet period (SLZB_RECONNECT_PAUSE) gives EFR32 time to complete
# its rapid NVM crash loop in isolation (no host to send RSTACK to). After
# reconnect, the proxy drains the single RSTACK from EFR32's final boot, then
# allows Z2M to connect to a stable EFR32.
# When False: SLZB stays connected; proxy drains all RSTACK frames directly —
# but EFR32's rapid crash loop keeps firing through the open TCP, which prevents
# EFR32 from stabilising before Z2M connects (observed: 560+ bytes vs ~31 bytes
# of stale data when True). Use False only for diagnostics.
RECONNECT_SLZB_AFTER_Z2M_DISCONNECT = True
SLZB_RECONNECT_PAUSE = 20.0  # seconds to wait after closing before reconnecting

_log_lock = threading.Lock()


def log(msg: str, level: int = syslog.LOG_INFO) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    with _log_lock:
        print(f"[{ts}] slzb-proxy: {msg}", flush=True)
    syslog.syslog(level, f"slzb-proxy: {msg}")


class SlzbConnection:
    """Persistent keep-alive connection to the SLZB adapter."""

    def __init__(self) -> None:
        self._sock: socket.socket | None = None
        self._lock = threading.Lock()
        self._connected = threading.Event()
        self._shutdown = False

    # ------------------------------------------------------------------
    # Connection management
    # ------------------------------------------------------------------

    def connect(self) -> None:
        """Establish (or re-establish) connection to SLZB, blocking until connected."""
        while not self._shutdown:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(10)
                sock.connect((SLZB_HOST, SLZB_PORT))
                sock.settimeout(None)  # blocking mode for normal I/O
                with self._lock:
                    self._sock = sock
                self._connected.set()
                log(f"Connected to SLZB at {SLZB_HOST}:{SLZB_PORT}")
                return
            except OSError as e:
                log(f"Failed to connect to SLZB: {e} — retrying in {RECONNECT_DELAY}s",
                    syslog.LOG_WARNING)
                time.sleep(RECONNECT_DELAY)

    def reconnect(self) -> None:
        """Drop current connection and re-establish."""
        self._connected.clear()
        with self._lock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None
        log("Reconnecting to SLZB...", syslog.LOG_WARNING)
        self.connect()

    def reconnect_after_pause(self, pause: float) -> None:
        """Close SLZB connection, wait pause seconds, then reconnect.

        The pause lets the EFR32 detect the host disconnect and commit pending
        NVM values to flash before we reconnect. Called after each Z2M session
        ends to enable NVM burn-in convergence.
        """
        self._connected.clear()
        with self._lock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None
        log(f"SLZB connection closed — waiting {pause}s for EFR32 NVM commit",
            syslog.LOG_INFO)
        time.sleep(pause)
        self.connect()

    def stop(self) -> None:
        self._shutdown = True
        self._connected.set()  # unblock any waiters
        with self._lock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None

    def wait_connected(self) -> None:
        self._connected.wait()

    # ------------------------------------------------------------------
    # Data I/O
    # ------------------------------------------------------------------

    def sendall(self, data: bytes) -> None:
        with self._lock:
            s = self._sock
        if s is None:
            raise OSError("Not connected")
        s.sendall(data)

    def recv_select(self, n: int, timeout: float) -> bytes | None:
        """Read up to n bytes with a select() timeout.

        Returns:
            bytes — data read (may be empty → connection closed)
            None  — select() timed out (no data within `timeout` seconds)

        Raises:
            OSError — socket error or not connected
        """
        with self._lock:
            s = self._sock
        if s is None:
            raise OSError("Not connected")
        try:
            rlist, _, _ = select.select([s], [], [], timeout)
        except (ValueError, OSError) as e:
            raise OSError(f"select error: {e}") from e
        if not rlist:
            return None  # timeout
        return s.recv(n)

    def drain(self, duration: float) -> None:
        """Read and discard all data arriving from SLZB for `duration` seconds.

        Called during the post-disconnect hold period to flush stale RSTACK
        frames that the EFR32 emits after completing a RESET_SOFTWARE boot.
        Without this, the next Z2M session would receive the stale RSTACK
        before sending RST and crash with HOST_FATAL_ERROR.
        """
        end = time.monotonic() + duration
        discarded = 0
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                break
            try:
                data = self.recv_select(4096, timeout=min(remaining, 0.5))
            except OSError as e:
                log(f"SLZB error during drain: {e} — reconnecting", syslog.LOG_WARNING)
                self.reconnect()
                return
            if data is None:
                continue  # select timeout — keep draining
            if not data:
                log("SLZB closed connection during drain — reconnecting", syslog.LOG_WARNING)
                self.reconnect()
                return
            discarded += len(data)
        if discarded:
            log(f"Drain complete — discarded {discarded} bytes of stale adapter data")


class ClientSession:
    """Manages a single Z2M connection, bridging it to the shared SLZB connection."""

    def __init__(self, client_sock: socket.socket, addr: tuple,
                 slzb: SlzbConnection) -> None:
        self.client_sock = client_sock
        self.addr = addr
        self.slzb = slzb
        self._stop = threading.Event()

    def run(self) -> None:
        log(f"Z2M client connected from {self.addr[0]}:{self.addr[1]}")
        self.slzb.wait_connected()

        t_c2s = threading.Thread(target=self._client_to_slzb, daemon=True)
        t_s2c = threading.Thread(target=self._slzb_to_client, daemon=True)
        t_c2s.start()
        t_s2c.start()
        t_c2s.join()
        t_s2c.join()

        try:
            self.client_sock.close()
        except OSError:
            pass
        log(f"Z2M client disconnected — SLZB connection preserved")

    def _client_to_slzb(self) -> None:
        """Forward Z2M → SLZB."""
        while not self._stop.is_set():
            try:
                data = self.client_sock.recv(4096)
                if not data:
                    self._stop.set()
                    return
                self.slzb.sendall(data)
            except OSError:
                self._stop.set()
                return

    def _slzb_to_client(self) -> None:
        """Forward SLZB → Z2M.

        Uses select() with a short timeout so _stop can be checked promptly.
        This prevents the thread from hanging forever when Z2M crashes with
        ASH_ERROR_TIMEOUTS (adapter sends no data, recv() would block forever).
        """
        while not self._stop.is_set():
            try:
                data = self.slzb.recv_select(4096, timeout=SLZB_SELECT_TIMEOUT)
            except OSError:
                self._stop.set()
                return
            if data is None:
                continue  # select timeout — loop back, check _stop
            if not data:
                # SLZB side closed — reconnect backend
                self._stop.set()
                log("SLZB closed connection unexpectedly — triggering reconnect",
                    syslog.LOG_WARNING)
                threading.Thread(target=self.slzb.reconnect, daemon=True).start()
                return
            try:
                self.client_sock.sendall(data)
            except OSError:
                self._stop.set()
                return


def force_recovery(server: socket.socket) -> None:
    """Refuse Z2M connections for FORCE_RESTART_STOP_DURATION, then exit.

    See failure mode 4 in the module docstring. On the Mac Mini this stopped the
    zigbee2mqtt container outright. In a pod the proxy cannot stop a sibling
    container, so it closes its listener instead: Z2M's connect attempts fail,
    Z2M exits, and the kubelet restarts it with its own backoff, which gives the
    EFR32 the same undisturbed window. Exiting afterwards restarts this sidecar
    with fresh sockets and threads.
    """
    log(f"No stable session (>= {STABLE_SESSION_DURATION:.0f}s) in over "
        f"{MAX_TIME_WITHOUT_STABLE_SESSION:.0f}s despite ongoing cycling - "
        f"refusing Z2M connections for {FORCE_RESTART_STOP_DURATION:.0f}s "
        "and restarting this proxy for a clean recovery attempt",
        syslog.LOG_WARNING)
    try:
        server.close()
    except OSError:
        pass
    time.sleep(FORCE_RESTART_STOP_DURATION)
    sys.exit(1)


def serve(slzb: SlzbConnection) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(1)
    log(f"Listening on {LISTEN_HOST}:{LISTEN_PORT} "
        f"(post-disconnect drain: {POST_DISCONNECT_DELAY}s)")

    last_disconnect = None  # None = first run, no hold needed
    consecutive_stale = 0   # tight-loop detector — see MAX_CONSECUTIVE_STALE
    last_stable_at = time.monotonic()  # process-stuck detector — see MAX_TIME_WITHOUT_STABLE_SESSION

    while True:
        # Hold and drain after each real Z2M disconnect.
        # last_disconnect is cleared (set to None) after drain completes, so
        # stale connections (< MIN_REAL_SESSION_DURATION) don't re-trigger drain.
        if last_disconnect is not None:
            elapsed = time.monotonic() - last_disconnect
            remaining = POST_DISCONNECT_DELAY - elapsed
            if remaining > 0:
                if RECONNECT_SLZB_AFTER_Z2M_DISCONNECT:
                    # Close and reconnect to SLZB so the EFR32 detects a host
                    # disconnect and completes its post-hard-reset initialization.
                    # SLZB_RECONNECT_PAUSE must be long enough for the EFR32 to
                    # complete its init cycle and spontaneous reset before Z2M
                    # reconnects (see module docstring for timing details).
                    log(f"Cycling SLZB connection — closing to trigger EFR32 NVM commit, "
                        f"reconnecting in {SLZB_RECONNECT_PAUSE}s")
                    slzb.reconnect_after_pause(SLZB_RECONNECT_PAUSE)
                    # Recalculate remaining drain time after reconnect
                    elapsed = time.monotonic() - last_disconnect
                    remaining = POST_DISCONNECT_DELAY - elapsed
                if remaining > 0:
                    log(f"Holding {remaining:.1f}s — draining stale adapter data")
                    slzb.drain(remaining)
            # Clear after drain — stale connections won't re-trigger drain cycle
            last_disconnect = None

        try:
            client_sock, addr = server.accept()
        except OSError as e:
            log(f"Accept error: {e}", syslog.LOG_ERR)
            break

        session_start = time.monotonic()
        session = ClientSession(client_sock, addr, slzb)
        session.run()  # synchronous — only one Z2M client at a time
        session_duration = time.monotonic() - session_start

        if session_duration >= STABLE_SESSION_DURATION:
            last_stable_at = time.monotonic()
        elif time.monotonic() - last_stable_at > MAX_TIME_WITHOUT_STABLE_SESSION:
            # Sessions have been long enough to clear MIN_REAL_SESSION_DURATION
            # (or the proxy is stale-cycling) but none has ever reached a genuinely
            # stable duration — the proxy's own reconnect/drain cycle is running
            # but not fixing anything. See failure mode 4 in the module docstring.
            force_recovery(server)  # does not return - closes the listener, holds, exits

        if session_duration < MIN_REAL_SESSION_DURATION:
            # Very short session = usually a stale socket (Z2M crashed before proxy
            # accepted it, leaving a CLOSE_WAIT connection in the OS backlog) — the
            # EFR32 state has not been disturbed, so a single one is safe to skip.
            # But a *run* of these means Z2M is tight-crash-looping and genuinely
            # failing its handshake every time — skipping forever starves the one
            # thing that actually recovers the coordinator. Force a cycle anyway
            # once that pattern is clear.
            consecutive_stale += 1
            log(f"Short session ({session_duration:.1f}s) — stale connection "
                f"(consecutive={consecutive_stale}), skipping SLZB cycle")
            if consecutive_stale >= MAX_CONSECUTIVE_STALE:
                log(f"{consecutive_stale} consecutive stale sessions — Z2M is tight-"
                    "crash-looping, forcing a full recovery cycle instead of spinning")
                last_disconnect = time.monotonic()
                consecutive_stale = 0
            continue

        consecutive_stale = 0
        last_disconnect = time.monotonic()


def main() -> None:
    log(f"Starting — forwarding {LISTEN_HOST}:{LISTEN_PORT} → {SLZB_HOST}:{SLZB_PORT}")
    slzb = SlzbConnection()
    slzb.connect()
    serve(slzb)


if __name__ == "__main__":
    main()
