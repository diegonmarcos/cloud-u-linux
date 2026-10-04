//! `/dev/uhid` USB-HID transport for CTAP2 — Phase B.5.
//!
//! Wire format reference: **CTAP HID Specification §8.1** (W3C / FIDO2 spec
//! "Client to Authenticator Protocol").  Every frame on the HID wire is
//! exactly **64 bytes**; messages longer than 57 bytes of payload are
//! split across one *initial* frame plus N *continuation* frames.
//!
//! ## Frame layout (CTAP HID §8.1)
//!
//! ```text
//! Initial frame (CTAPHID_INIT_FRAME):
//!     bytes 0..=3   channel ID            (u32, big-endian)
//!     byte  4       command | 0x80        (high bit set = initial)
//!     bytes 5..=6   total payload length  (u16, big-endian, BCNT)
//!     bytes 7..=63  first 57 bytes of payload
//!
//! Continuation frame (CTAPHID_CONT_FRAME):
//!     bytes 0..=3   channel ID            (u32, big-endian)
//!     byte  4       sequence number       (0..=127, high bit clear)
//!     bytes 5..=63  next 59 bytes of payload
//! ```
//!
//! The sequence numbers run **0, 1, 2, …** (not the channel id again).
//!
//! ## Module layout
//!
//! * Pure parsing/framing helpers — exported as standalone functions and
//!   covered by unit tests.  These are independent of any I/O and are
//!   the bulk of the byte-level fiddly logic.
//! * Channel-management state — also pure, kept in a `HashMap`.
//! * `UhidServer` — owns the `/dev/uhid` file descriptor and runs the
//!   read/write loop.  Only compiled with `--features fido2` because
//!   `uhid-virt` transitively requires `bindgen` + libclang, which
//!   inflates default `cargo build` time.
//!
//! ## Integration with CTAP2 (B.4)
//!
//! `UhidServer::run` takes a callback `on_cbor: FnMut(u8, &[u8]) -> Vec<u8>`
//! that is invoked for every fully-reassembled `CTAPHID_CBOR` message.
//! The callback returns the response bytes including the leading status
//! byte; the HID layer then fragments those back into 64-byte frames.

#![allow(clippy::module_name_repetitions)]

use crate::error::{BrokerError, Result};
use std::collections::HashMap;
use std::time::{Duration, Instant};

// ─── Constants from CTAP HID §8 ───────────────────────────────────────

/// Every HID report is exactly 64 bytes.
pub const HID_FRAME_SIZE: usize = 64;

/// Initial frame carries up to 57 bytes of payload.
pub const INIT_FRAME_PAYLOAD: usize = HID_FRAME_SIZE - 7;

/// Continuation frame carries up to 59 bytes of payload.
pub const CONT_FRAME_PAYLOAD: usize = HID_FRAME_SIZE - 5;

/// Maximum message length per CTAP HID §8.1 (16-bit BCNT).
pub const MAX_PAYLOAD_LEN: usize = 7609;

/// Broadcast channel — every device starts conversations here, the
/// server responds with `CTAPHID_INIT` allocating a real channel.
pub const CTAPHID_BROADCAST_CID: u32 = 0xffff_ffff;

// CTAP HID command bytes (CTAP HID §8.1).  All are OR'd with 0x80 in the
// initial-frame command byte; the constants here are the *bare* values.
pub const CTAPHID_PING: u8 = 0x01;
pub const CTAPHID_MSG: u8 = 0x03;
pub const CTAPHID_INIT: u8 = 0x06;
pub const CTAPHID_WINK: u8 = 0x08;
pub const CTAPHID_CBOR: u8 = 0x10;
pub const CTAPHID_CANCEL: u8 = 0x11;
pub const CTAPHID_KEEPALIVE: u8 = 0x3b;
pub const CTAPHID_ERROR: u8 = 0x3f;

// CTAPHID_KEEPALIVE status bytes (CTAP HID §8.1.9.1).
pub const KEEPALIVE_PROCESSING: u8 = 0x01;
pub const KEEPALIVE_UP_NEEDED: u8 = 0x02;

// CTAPHID_ERROR codes (CTAP HID §8.1.9.2).
pub const ERR_INVALID_CMD: u8 = 0x01;
pub const ERR_INVALID_PAR: u8 = 0x02;
pub const ERR_INVALID_LEN: u8 = 0x03;
pub const ERR_INVALID_SEQ: u8 = 0x04;
pub const ERR_MSG_TIMEOUT: u8 = 0x05;
pub const ERR_CHANNEL_BUSY: u8 = 0x06;
pub const ERR_OTHER: u8 = 0x7f;

/// Capability flags used in CTAPHID_INIT response (CTAP HID §8.1.9.1.3).
pub const CAP_WINK: u8 = 0x01;
pub const CAP_CBOR: u8 = 0x04;
/// Tells host this authenticator does NOT support legacy U2F (NMSG bit).
pub const CAP_NMSG: u8 = 0x08;

/// Channels idle longer than this are reaped on the next housekeeping pass.
pub const CHANNEL_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

// FIDO2 HID Report Descriptor (Usage Page 0xF1D0, Usage 0x01).  The kernel
// hands this to userspace so applications like `webauthn-rs` recognise the
// virtual device as a FIDO2 authenticator.
pub const FIDO_HID_REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0xD0, 0xF1, // Usage Page (FIDO Alliance, 0xF1D0)
    0x09, 0x01, // Usage (U2F HID Authenticator Device)
    0xA1, 0x01, // Collection (Application)
    0x09, 0x20, //   Usage (Input Report Data)
    0x15, 0x00, //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08, //   Report Size (8)
    0x95, 0x40, //   Report Count (64)
    0x81, 0x02, //   Input (Data, Variable, Absolute)
    0x09, 0x21, //   Usage (Output Report Data)
    0x15, 0x00, //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08, //   Report Size (8)
    0x95, 0x40, //   Report Count (64)
    0x91, 0x02, //   Output (Data, Variable, Absolute)
    0xC0, // End Collection
];

// ─── Frame parsing ────────────────────────────────────────────────────

/// A parsed CTAP HID *initial* frame.
///
/// `payload` holds at most 57 bytes (the initial-frame slot).  `total_len`
/// is the BCNT field — the assembler uses it to know when reassembly is
/// complete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InitialFrame {
    pub channel: u32,
    pub command: u8,
    pub total_len: u16,
    pub payload: Vec<u8>,
}

/// A parsed CTAP HID *continuation* frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContinuationFrame {
    pub channel: u32,
    pub sequence: u8,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedFrame {
    Initial(InitialFrame),
    Continuation(ContinuationFrame),
}

/// Decode a 64-byte HID report.  Returns `Initial` if bit 7 of byte 4 is
/// set, otherwise `Continuation`.
///
/// CTAP HID §8.1.1: "The most significant bit of CMD differentiates
/// between initialization (1) and continuation (0) packets."
pub fn parse_frame(buf: &[u8]) -> Result<ParsedFrame> {
    if buf.len() != HID_FRAME_SIZE {
        return Err(BrokerError::Uhid(format!(
            "expected {HID_FRAME_SIZE}-byte HID frame, got {}",
            buf.len()
        )));
    }
    let channel = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]);
    let cmd_or_seq = buf[4];
    if cmd_or_seq & 0x80 != 0 {
        Ok(ParsedFrame::Initial(parse_initial_frame(buf)?))
    } else {
        Ok(ParsedFrame::Continuation(ContinuationFrame {
            channel,
            sequence: cmd_or_seq & 0x7f,
            payload: buf[5..].to_vec(),
        }))
    }
}

/// Decode a 64-byte HID report assumed to be an initial frame.
///
/// CTAP HID §8.1.1.1: byte 4 has the high bit set; bytes 5..=6 hold the
/// total payload length (BCNT) in big-endian; bytes 7..=63 hold up to 57
/// bytes of payload.  We truncate the payload slice to `min(BCNT, 57)`
/// because trailing bytes inside a single-frame message are pad and
/// **must not** be treated as message bytes.
pub fn parse_initial_frame(buf: &[u8]) -> Result<InitialFrame> {
    if buf.len() != HID_FRAME_SIZE {
        return Err(BrokerError::Uhid(format!(
            "initial frame must be {HID_FRAME_SIZE} bytes"
        )));
    }
    if buf[4] & 0x80 == 0 {
        return Err(BrokerError::Uhid(
            "initial frame missing high bit in command byte".into(),
        ));
    }
    let channel = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]);
    let command = buf[4] & 0x7f;
    let total_len = u16::from_be_bytes([buf[5], buf[6]]);
    if total_len as usize > MAX_PAYLOAD_LEN {
        return Err(BrokerError::Uhid(format!(
            "BCNT {total_len} exceeds CTAP HID max {MAX_PAYLOAD_LEN}"
        )));
    }
    let take = (total_len as usize).min(INIT_FRAME_PAYLOAD);
    Ok(InitialFrame {
        channel,
        command,
        total_len,
        payload: buf[7..7 + take].to_vec(),
    })
}

/// Decode a 64-byte HID report assumed to be a continuation frame.
///
/// CTAP HID §8.1.1.2: byte 4 is a 7-bit sequence counter; the high bit is
/// always 0 (already verified by `parse_frame`).
pub fn parse_continuation_frame(buf: &[u8]) -> Result<ContinuationFrame> {
    if buf.len() != HID_FRAME_SIZE {
        return Err(BrokerError::Uhid(format!(
            "continuation frame must be {HID_FRAME_SIZE} bytes"
        )));
    }
    if buf[4] & 0x80 != 0 {
        return Err(BrokerError::Uhid(
            "continuation frame must not have high bit set".into(),
        ));
    }
    Ok(ContinuationFrame {
        channel: u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]),
        sequence: buf[4] & 0x7f,
        payload: buf[5..].to_vec(),
    })
}

// ─── Frame fragmentation (response side) ──────────────────────────────

/// Fragment an outbound message into 64-byte HID frames.
///
/// Pads the last frame with zeros (CTAP HID §8.1.2).  The first frame
/// carries `command | 0x80`; subsequent frames carry sequence numbers
/// 0, 1, 2, … (not the high bit, not 0x80).
///
/// Sequence numbers are 7-bit so a single message tops out at:
///     57 + 128 * 59 = 7609 bytes (`MAX_PAYLOAD_LEN`).
pub fn fragment_response(channel: u32, command: u8, payload: &[u8]) -> Result<Vec<[u8; 64]>> {
    if payload.len() > MAX_PAYLOAD_LEN {
        return Err(BrokerError::Uhid(format!(
            "response payload {} > max {}",
            payload.len(),
            MAX_PAYLOAD_LEN
        )));
    }

    let mut frames: Vec<[u8; 64]> = Vec::new();
    let cid = channel.to_be_bytes();
    let total_len = (payload.len() as u16).to_be_bytes();

    // Initial frame.
    let mut first = [0u8; HID_FRAME_SIZE];
    first[0..4].copy_from_slice(&cid);
    first[4] = command | 0x80;
    first[5..7].copy_from_slice(&total_len);
    let first_take = payload.len().min(INIT_FRAME_PAYLOAD);
    first[7..7 + first_take].copy_from_slice(&payload[..first_take]);
    frames.push(first);

    // Continuation frames.
    let mut offset = first_take;
    let mut seq: u8 = 0;
    while offset < payload.len() {
        if seq > 0x7f {
            return Err(BrokerError::Uhid(
                "fragmentation overflow: seq > 127 (message too large)".into(),
            ));
        }
        let mut frame = [0u8; HID_FRAME_SIZE];
        frame[0..4].copy_from_slice(&cid);
        frame[4] = seq;
        let take = (payload.len() - offset).min(CONT_FRAME_PAYLOAD);
        frame[5..5 + take].copy_from_slice(&payload[offset..offset + take]);
        frames.push(frame);
        offset += take;
        seq += 1;
    }

    Ok(frames)
}

/// Build a `CTAPHID_ERROR` response frame for the given channel / code.
pub fn build_error_frame(channel: u32, code: u8) -> [u8; 64] {
    // ERROR responses have a 1-byte payload (the code).  Always one frame.
    let frames = fragment_response(channel, CTAPHID_ERROR, &[code])
        .expect("single-byte error always fits in one frame");
    frames[0]
}

/// Build a `CTAPHID_KEEPALIVE` frame for the given channel / status.
pub fn build_keepalive_frame(channel: u32, status: u8) -> [u8; 64] {
    let frames = fragment_response(channel, CTAPHID_KEEPALIVE, &[status])
        .expect("single-byte keepalive always fits in one frame");
    frames[0]
}

// ─── Channel state ────────────────────────────────────────────────────

/// Per-channel reassembly state.
///
/// The CTAP HID spec mandates that each channel can have **one**
/// in-flight message at a time; if a new initial frame arrives while
/// an old one is incomplete we must respond with `ERR_CHANNEL_BUSY`.
#[derive(Debug)]
pub struct ChannelState {
    pub command: u8,
    pub total_len: u16,
    pub buffer: Vec<u8>,
    pub next_seq: u8,
    pub last_seen: Instant,
}

impl ChannelState {
    pub fn new(initial: &InitialFrame) -> Self {
        Self {
            command: initial.command,
            total_len: initial.total_len,
            buffer: initial.payload.clone(),
            next_seq: 0,
            last_seen: Instant::now(),
        }
    }

    /// Returns `true` once `buffer.len() == total_len`.
    pub fn is_complete(&self) -> bool {
        self.buffer.len() >= self.total_len as usize
    }

    /// Append a continuation frame's payload.  Returns `Err` on sequence
    /// mismatch (CTAP HID §8.1.1.2 — sequences must be strictly
    /// monotonic from 0).
    pub fn append(&mut self, cont: &ContinuationFrame) -> Result<()> {
        if cont.sequence != self.next_seq {
            return Err(BrokerError::Uhid(format!(
                "sequence mismatch: expected {}, got {}",
                self.next_seq, cont.sequence
            )));
        }
        let remaining = (self.total_len as usize).saturating_sub(self.buffer.len());
        let take = remaining.min(cont.payload.len());
        self.buffer.extend_from_slice(&cont.payload[..take]);
        self.next_seq = self.next_seq.wrapping_add(1) & 0x7f;
        self.last_seen = Instant::now();
        Ok(())
    }
}

/// Container for all live channels.  `next_cid` allocates monotonically;
/// 0xffffffff is reserved for broadcast.
#[derive(Debug, Default)]
pub struct ChannelTable {
    pub channels: HashMap<u32, ChannelState>,
    pub next_cid: u32,
}

impl ChannelTable {
    pub fn new() -> Self {
        Self {
            channels: HashMap::new(),
            // CIDs start at 1; 0 and 0xffffffff are reserved.
            next_cid: 1,
        }
    }

    /// Allocate a new channel id.  Skips 0 and broadcast.
    pub fn allocate_cid(&mut self) -> u32 {
        loop {
            let cid = self.next_cid;
            self.next_cid = self.next_cid.wrapping_add(1);
            if cid != 0 && cid != CTAPHID_BROADCAST_CID && !self.channels.contains_key(&cid) {
                return cid;
            }
        }
    }

    /// Drop channels whose `last_seen` is older than `CHANNEL_IDLE_TIMEOUT`.
    pub fn gc(&mut self) {
        let now = Instant::now();
        self.channels
            .retain(|_, st| now.duration_since(st.last_seen) <= CHANNEL_IDLE_TIMEOUT);
    }
}

// ─── CTAPHID_INIT response builder ────────────────────────────────────

/// Build the body of a `CTAPHID_INIT` response (CTAP HID §8.1.9.1.3):
///
/// ```text
/// 0..=7    nonce (echoed from the request)
/// 8..=11   newly-allocated channel id (u32 BE)
/// 12       CTAPHID protocol version (= 2)
/// 13       device version major
/// 14       device version minor
/// 15       device build version
/// 16       capabilities flags
/// ```
pub fn build_init_response(nonce: &[u8; 8], new_cid: u32, capabilities: u8) -> Vec<u8> {
    let mut body = Vec::with_capacity(17);
    body.extend_from_slice(nonce);
    body.extend_from_slice(&new_cid.to_be_bytes());
    body.push(2); // CTAPHID protocol version
    body.push(env!("CARGO_PKG_VERSION_MAJOR").parse().unwrap_or(0));
    body.push(env!("CARGO_PKG_VERSION_MINOR").parse().unwrap_or(1));
    body.push(env!("CARGO_PKG_VERSION_PATCH").parse().unwrap_or(0));
    body.push(capabilities);
    body
}

// ─── UhidServer ───────────────────────────────────────────────────────

/// Owns `/dev/uhid`, runs the HID I/O loop, and dispatches CBOR messages
/// to the CTAP2 layer.
///
/// This is intentionally `Send`-able so the broker can run it on a
/// dedicated tokio task while the BW-API sync runs on another.
pub struct UhidServer {
    aaguid: [u8; 16],
    channels: ChannelTable,
}

impl UhidServer {
    /// Construct a server bound to the supplied 16-byte AAGUID.  The
    /// AAGUID is what the CTAP2 layer reports in `authenticatorGetInfo`;
    /// it does not influence the HID transport itself but we keep it
    /// here so the broker has one place to ferry it through.
    pub fn new(aaguid: [u8; 16]) -> Self {
        Self {
            aaguid,
            channels: ChannelTable::new(),
        }
    }

    /// Read-only accessor.
    pub fn aaguid(&self) -> [u8; 16] {
        self.aaguid
    }

    /// Drive the HID transport until cancellation.
    ///
    /// **Callback contract** — the CTAP2 layer hands us a closure
    /// `on_cbor: FnMut(u8, &[u8]) -> Vec<u8>`:
    ///   * `cmd_byte` — the CTAP2 command (e.g. 0x01 = makeCredential)
    ///     stripped from the first byte of the CBOR payload
    ///   * `payload` — the remainder of the CBOR-encoded request
    ///   * **return** — the CBOR-encoded response **including** the
    ///     leading status byte (0x00 = success, otherwise CTAP2 error)
    ///
    /// The HID layer fragments that return value back into 64-byte HID
    /// frames addressed to the originating channel.
    ///
    /// Without the `fido2` feature this returns `BrokerError::UhidNotImplemented`.
    /// The build feature exists because `uhid-virt` pulls in `bindgen`,
    /// which is a substantial build-time dependency we don't want
    /// imposed on default `cargo test` runs.
    #[allow(unused_variables)]
    pub async fn run<F>(&mut self, on_cbor: F) -> Result<()>
    where
        F: FnMut(u8, &[u8]) -> Vec<u8> + Send + 'static,
    {
        #[cfg(feature = "fido2")]
        {
            self.run_inner(on_cbor).await
        }
        #[cfg(not(feature = "fido2"))]
        {
            Err(BrokerError::UhidNotImplemented)
        }
    }

    #[cfg(feature = "fido2")]
    async fn run_inner<F>(&mut self, mut on_cbor: F) -> Result<()>
    where
        F: FnMut(u8, &[u8]) -> Vec<u8> + Send + 'static,
    {
        use std::path::Path;
        use uhid_virt::{Bus, CreateParams, OutputEvent, UHIDDevice};

        // Block on the synchronous open in a blocking task — uhid-virt
        // is sync-only.
        let mut device = tokio::task::spawn_blocking(|| {
            UHIDDevice::create_with_path(
                CreateParams {
                    name: "fido2-vault-broker".into(),
                    phys: "".into(),
                    uniq: "".into(),
                    bus: Bus::USB,
                    vendor: 0xf1d0,
                    product: 0x0001,
                    version: 0,
                    country: 0,
                    rd_data: FIDO_HID_REPORT_DESCRIPTOR.to_vec(),
                },
                Path::new("/dev/uhid"),
            )
        })
        .await
        .map_err(|e| BrokerError::Uhid(format!("uhid open task panic: {e}")))?
        .map_err(|e| BrokerError::Uhid(format!("uhid open: {e}")))?;

        tracing::info!("uhid: registered virtual FIDO2 authenticator");

        loop {
            // uhid-virt's read() is a blocking syscall; we loop on a
            // short timeout so we can also do channel GC.
            let read_result = tokio::task::block_in_place(|| device.read());
            let event = match read_result {
                Ok(ev) => ev,
                Err(uhid_virt::StreamError::Io(e))
                    if e.kind() == std::io::ErrorKind::WouldBlock =>
                {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    self.channels.gc();
                    continue;
                }
                Err(uhid_virt::StreamError::Io(io)) => {
                    return Err(BrokerError::Uhid(format!("uhid read: io: {io}")));
                }
                Err(uhid_virt::StreamError::UnknownEventType(t)) => {
                    return Err(BrokerError::Uhid(format!(
                        "uhid read: unknown event type {t}"
                    )));
                }
            };

            match event {
                OutputEvent::Output { data } => {
                    if data.len() != HID_FRAME_SIZE {
                        tracing::warn!(len = data.len(), "ignoring non-64-byte HID frame");
                        continue;
                    }
                    let response_frames = self.handle_frame(&data, &mut on_cbor)?;
                    for f in response_frames {
                        if let Err(e) = device.write(&f) {
                            return Err(BrokerError::Uhid(format!("uhid write: {e}")));
                        }
                    }
                }
                OutputEvent::Stop | OutputEvent::Close => {
                    // UHID_STOP / UHID_CLOSE: kernel signalling that the
                    // last reader (browser hidraw fd) closed, OR the kernel
                    // is asking us to pause output reports temporarily.
                    // Neither means our authenticator should exit — the
                    // browser will reconnect and trigger UHID_OPEN/UHID_START
                    // next time it polls. Log and keep the read loop alive.
                    tracing::debug!("uhid: device stop/close event — pausing, daemon continues");
                    continue;
                }
                _ => {} // Start, Open, GetReport, SetReport — ignore for now
            }
        }
    }

    /// Process one 64-byte HID frame and return the frames to write back.
    ///
    /// Public for testability (state is fully observable and deterministic).
    pub fn handle_frame<F>(&mut self, frame: &[u8], on_cbor: &mut F) -> Result<Vec<[u8; 64]>>
    where
        F: FnMut(u8, &[u8]) -> Vec<u8>,
    {
        let parsed = parse_frame(frame)?;
        match parsed {
            ParsedFrame::Initial(init) => self.on_initial(init, on_cbor),
            ParsedFrame::Continuation(cont) => self.on_continuation(cont, on_cbor),
        }
    }

    fn on_initial<F>(&mut self, init: InitialFrame, on_cbor: &mut F) -> Result<Vec<[u8; 64]>>
    where
        F: FnMut(u8, &[u8]) -> Vec<u8>,
    {
        if init.command == CTAPHID_INIT {
            return self.handle_init(&init);
        }

        if init.channel == CTAPHID_BROADCAST_CID {
            // Only INIT is allowed on the broadcast channel.
            return Ok(vec![build_error_frame(init.channel, ERR_INVALID_CMD)]);
        }

        // Reject if a different message is already in flight on this channel.
        if let Some(existing) = self.channels.get(&init.channel) {
            if !existing.is_complete() {
                return Ok(vec![build_error_frame(init.channel, ERR_CHANNEL_BUSY)]);
            }
        }

        let state = ChannelState::new(&init);
        if state.is_complete() {
            // Single-frame message — dispatch immediately.
            let frames = self.dispatch_complete(init.channel, &state, on_cbor);
            // Single-frame messages don't need persisted state, but we
            // keep an entry so GC can age it out.
            self.channels.channels.insert(init.channel, state);
            return Ok(frames);
        }
        self.channels.channels.insert(init.channel, state);
        Ok(vec![]) // wait for continuations
    }

    fn on_continuation<F>(
        &mut self,
        cont: ContinuationFrame,
        on_cbor: &mut F,
    ) -> Result<Vec<[u8; 64]>>
    where
        F: FnMut(u8, &[u8]) -> Vec<u8>,
    {
        let state = match self.channels.channels.get_mut(&cont.channel) {
            Some(s) => s,
            None => {
                return Ok(vec![build_error_frame(cont.channel, ERR_INVALID_CMD)]);
            }
        };
        if let Err(_e) = state.append(&cont) {
            // Drop the half-assembled message and surface ERR_INVALID_SEQ.
            self.channels.channels.remove(&cont.channel);
            return Ok(vec![build_error_frame(cont.channel, ERR_INVALID_SEQ)]);
        }
        if !state.is_complete() {
            return Ok(vec![]);
        }
        // Take ownership of the now-complete state so we can dispatch
        // without holding a mutable borrow of self.channels.
        let cid = cont.channel;
        let state = self.channels.channels.remove(&cid).expect("just-checked");
        let frames = self.dispatch_complete(cid, &state, on_cbor);
        // Keep an empty slot so subsequent INITs don't see "channel busy".
        self.channels.channels.insert(
            cid,
            ChannelState {
                command: 0,
                total_len: 0,
                buffer: vec![],
                next_seq: 0,
                last_seen: Instant::now(),
            },
        );
        Ok(frames)
    }

    fn handle_init(&mut self, init: &InitialFrame) -> Result<Vec<[u8; 64]>> {
        // CTAPHID_INIT payload is exactly 8 bytes (the nonce).
        if init.total_len as usize != 8 || init.payload.len() < 8 {
            return Ok(vec![build_error_frame(init.channel, ERR_INVALID_LEN)]);
        }
        let mut nonce = [0u8; 8];
        nonce.copy_from_slice(&init.payload[..8]);

        let new_cid = if init.channel == CTAPHID_BROADCAST_CID {
            self.channels.allocate_cid()
        } else {
            // Re-INIT on an existing channel resets it (CTAP HID §8.1.9.1.3).
            self.channels.channels.remove(&init.channel);
            init.channel
        };

        // Seed an empty channel-state for the newly-issued CID so future
        // continuations on it can find a slot.
        self.channels.channels.insert(
            new_cid,
            ChannelState {
                command: 0,
                total_len: 0,
                buffer: vec![],
                next_seq: 0,
                last_seen: Instant::now(),
            },
        );

        let body = build_init_response(&nonce, new_cid, CAP_CBOR | CAP_NMSG | CAP_WINK);
        let frames = fragment_response(init.channel, CTAPHID_INIT, &body)?;
        Ok(frames)
    }

    /// Once a full message is reassembled, dispatch by command type.
    fn dispatch_complete<F>(
        &mut self,
        channel: u32,
        state: &ChannelState,
        on_cbor: &mut F,
    ) -> Vec<[u8; 64]>
    where
        F: FnMut(u8, &[u8]) -> Vec<u8>,
    {
        match state.command {
            CTAPHID_PING => {
                // Echo the payload back.
                fragment_response(channel, CTAPHID_PING, &state.buffer)
                    .unwrap_or_else(|_| vec![build_error_frame(channel, ERR_OTHER)])
            }
            CTAPHID_MSG => {
                // Legacy U2F path — we don't implement it.  Return the
                // U2F status word for "conditions-not-satisfied" (0x6985).
                fragment_response(channel, CTAPHID_MSG, &[0x69, 0x85])
                    .unwrap_or_else(|_| vec![build_error_frame(channel, ERR_OTHER)])
            }
            CTAPHID_CBOR => {
                if state.buffer.is_empty() {
                    return vec![build_error_frame(channel, ERR_INVALID_LEN)];
                }
                let cmd_byte = state.buffer[0];
                let response = on_cbor(cmd_byte, &state.buffer[1..]);
                fragment_response(channel, CTAPHID_CBOR, &response)
                    .unwrap_or_else(|_| vec![build_error_frame(channel, ERR_OTHER)])
            }
            CTAPHID_CANCEL => {
                // Best-effort: B.4's authenticator gets a 0-byte CBOR call
                // with command 0xff (reserved) so it can short-circuit any
                // pending UP wait.  In practice the cancel token is owned
                // there; we just acknowledge.
                fragment_response(channel, CTAPHID_CANCEL, &[])
                    .unwrap_or_else(|_| vec![build_error_frame(channel, ERR_OTHER)])
            }
            CTAPHID_WINK => {
                // No-op visual feedback.  A real device might pulse an LED.
                fragment_response(channel, CTAPHID_WINK, &[])
                    .unwrap_or_else(|_| vec![build_error_frame(channel, ERR_OTHER)])
            }
            other => {
                tracing::warn!(cmd = %format_args!("0x{other:02x}"), "unknown CTAPHID command");
                vec![build_error_frame(channel, ERR_INVALID_CMD)]
            }
        }
    }
}

// `ChannelTable::get` helper — small enough to live inline.
impl ChannelTable {
    fn get(&self, cid: &u32) -> Option<&ChannelState> {
        self.channels.get(cid)
    }
}

// ─── Backwards-compatible stub entrypoint ─────────────────────────────

/// Legacy entrypoint kept so `main.rs` (Phase B.1) still compiles.
/// New code should construct `UhidServer` and call `.run(...)`.
pub async fn run_loop(_uhid_path: &std::path::Path) -> Result<()> {
    Err(crate::BrokerError::UhidNotImplemented)
}

// ─── Unit tests ───────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: build a 64-byte frame with synthetic header + payload.
    fn make_initial(channel: u32, command: u8, total_len: u16, payload_seed: u8) -> [u8; 64] {
        let mut f = [0u8; 64];
        f[0..4].copy_from_slice(&channel.to_be_bytes());
        f[4] = command | 0x80;
        f[5..7].copy_from_slice(&total_len.to_be_bytes());
        for (i, slot) in f[7..].iter_mut().enumerate() {
            *slot = payload_seed.wrapping_add(i as u8);
        }
        f
    }

    fn make_continuation(channel: u32, seq: u8, payload_seed: u8) -> [u8; 64] {
        let mut f = [0u8; 64];
        f[0..4].copy_from_slice(&channel.to_be_bytes());
        f[4] = seq & 0x7f;
        for (i, slot) in f[5..].iter_mut().enumerate() {
            *slot = payload_seed.wrapping_add(i as u8);
        }
        f
    }

    #[test]
    fn parse_initial_frame_parses_header_and_payload() {
        let frame = make_initial(0xdead_beef, CTAPHID_CBOR, 30, 0x10);
        let p = parse_initial_frame(&frame).expect("ok");
        assert_eq!(p.channel, 0xdead_beef);
        assert_eq!(p.command, CTAPHID_CBOR);
        assert_eq!(p.total_len, 30);
        // The first 30 bytes of buf[7..] starting at 0x10, 0x11, …
        assert_eq!(p.payload.len(), 30);
        assert_eq!(p.payload[0], 0x10);
        assert_eq!(p.payload[29], 0x10 + 29);
    }

    #[test]
    fn parse_initial_rejects_missing_high_bit() {
        let mut frame = make_initial(1, CTAPHID_PING, 5, 0);
        frame[4] &= 0x7f; // strip high bit
        assert!(parse_initial_frame(&frame).is_err());
    }

    #[test]
    fn parse_continuation_frame_extracts_sequence_and_payload() {
        let frame = make_continuation(0xcafe_babe, 5, 0xa0);
        let c = parse_continuation_frame(&frame).expect("ok");
        assert_eq!(c.channel, 0xcafe_babe);
        assert_eq!(c.sequence, 5);
        assert_eq!(c.payload.len(), CONT_FRAME_PAYLOAD);
        assert_eq!(c.payload[0], 0xa0);
        assert_eq!(c.payload[58], 0xa0u8.wrapping_add(58));
    }

    #[test]
    fn reassemble_two_frame_message() {
        // Total payload = 80 bytes.  First 57 in initial frame,
        // remaining 23 in continuation seq=0.
        let payload: Vec<u8> = (0..80u8).collect();
        let mut f1 = [0u8; 64];
        f1[0..4].copy_from_slice(&0x1234_5678u32.to_be_bytes());
        f1[4] = CTAPHID_CBOR | 0x80;
        f1[5..7].copy_from_slice(&80u16.to_be_bytes());
        f1[7..7 + INIT_FRAME_PAYLOAD].copy_from_slice(&payload[..INIT_FRAME_PAYLOAD]);

        let mut f2 = [0u8; 64];
        f2[0..4].copy_from_slice(&0x1234_5678u32.to_be_bytes());
        f2[4] = 0; // seq 0
        let remaining = &payload[INIT_FRAME_PAYLOAD..];
        f2[5..5 + remaining.len()].copy_from_slice(remaining);

        let init = parse_initial_frame(&f1).unwrap();
        let cont = parse_continuation_frame(&f2).unwrap();

        let mut state = ChannelState::new(&init);
        assert!(!state.is_complete());
        state.append(&cont).expect("seq matches");
        assert!(state.is_complete());
        assert_eq!(state.buffer, payload);
    }

    #[test]
    fn fragment_response_three_frames_for_120_bytes() {
        // 120-byte response → 1 init (57) + 2 cont (59 + 4)
        let payload: Vec<u8> = (0..120u8).collect();
        let frames = fragment_response(0xaaaa_aaaa, CTAPHID_CBOR, &payload).unwrap();
        assert_eq!(frames.len(), 3);

        // Initial frame
        assert_eq!(frames[0][4], CTAPHID_CBOR | 0x80);
        assert_eq!(u16::from_be_bytes([frames[0][5], frames[0][6]]), 120);
        assert_eq!(&frames[0][7..7 + INIT_FRAME_PAYLOAD], &payload[..57]);

        // Continuation 0
        assert_eq!(frames[1][4], 0);
        assert_eq!(&frames[1][5..5 + CONT_FRAME_PAYLOAD], &payload[57..116]);

        // Continuation 1 (last 4 bytes payload + zero pad)
        assert_eq!(frames[2][4], 1);
        assert_eq!(&frames[2][5..9], &payload[116..120]);
        // Tail must be zero-padded.
        assert!(frames[2][9..].iter().all(|b| *b == 0));
    }

    #[test]
    fn fragment_response_four_frames_for_200_bytes() {
        // 200 bytes = 57 + 59 + 59 + 25 → 4 frames.
        let payload: Vec<u8> = (0..200u8).map(|i| i.wrapping_mul(3)).collect();
        let frames = fragment_response(1, CTAPHID_CBOR, &payload).unwrap();
        assert_eq!(frames.len(), 4);
        assert_eq!(frames[0][4], CTAPHID_CBOR | 0x80);
        assert_eq!(frames[1][4], 0);
        assert_eq!(frames[2][4], 1);
        assert_eq!(frames[3][4], 2);

        // Reassemble and compare.
        let mut got = Vec::new();
        got.extend_from_slice(&frames[0][7..]);
        got.extend_from_slice(&frames[1][5..]);
        got.extend_from_slice(&frames[2][5..]);
        got.extend_from_slice(&frames[3][5..]);
        got.truncate(payload.len());
        assert_eq!(got, payload);
    }

    #[test]
    fn init_command_response_echoes_nonce_and_allocates_channel() {
        let mut server = UhidServer::new([0u8; 16]);
        // Build a CTAPHID_INIT frame on the broadcast channel.
        let mut frame = [0u8; 64];
        frame[0..4].copy_from_slice(&CTAPHID_BROADCAST_CID.to_be_bytes());
        frame[4] = CTAPHID_INIT | 0x80;
        frame[5..7].copy_from_slice(&8u16.to_be_bytes());
        let nonce = [0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18];
        frame[7..15].copy_from_slice(&nonce);

        let mut cb = |_cmd: u8, _payload: &[u8]| -> Vec<u8> { vec![] };
        let response_frames = server.handle_frame(&frame, &mut cb).unwrap();
        assert_eq!(response_frames.len(), 1);
        let resp = response_frames[0];

        // Header: channel = broadcast, cmd = CTAPHID_INIT | 0x80, BCNT = 17
        assert_eq!(
            u32::from_be_bytes([resp[0], resp[1], resp[2], resp[3]]),
            CTAPHID_BROADCAST_CID
        );
        assert_eq!(resp[4], CTAPHID_INIT | 0x80);
        assert_eq!(u16::from_be_bytes([resp[5], resp[6]]), 17);

        // Body
        assert_eq!(&resp[7..15], &nonce, "nonce echo");
        let new_cid = u32::from_be_bytes([resp[15], resp[16], resp[17], resp[18]]);
        assert!(new_cid != 0 && new_cid != CTAPHID_BROADCAST_CID);
        assert_eq!(resp[19], 2, "CTAPHID protocol version");
        // resp[20..23] = device version (cargo pkg version, varies)
        let caps = resp[23];
        assert!(caps & CAP_CBOR != 0);
        assert!(caps & CAP_NMSG != 0);

        // Server allocated a new channel slot.
        assert!(server.channels.channels.contains_key(&new_cid));
    }

    #[test]
    fn ping_round_trips_through_server() {
        let mut server = UhidServer::new([0u8; 16]);
        // First INIT to get a real channel.
        let init_frame = {
            let mut f = [0u8; 64];
            f[0..4].copy_from_slice(&CTAPHID_BROADCAST_CID.to_be_bytes());
            f[4] = CTAPHID_INIT | 0x80;
            f[5..7].copy_from_slice(&8u16.to_be_bytes());
            f[7..15].copy_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
            f
        };
        let mut cb = |_: u8, _: &[u8]| Vec::<u8>::new();
        let init_resp = server.handle_frame(&init_frame, &mut cb).unwrap();
        let cid = u32::from_be_bytes([
            init_resp[0][15],
            init_resp[0][16],
            init_resp[0][17],
            init_resp[0][18],
        ]);

        // Now PING with 4-byte payload.
        let mut ping = [0u8; 64];
        ping[0..4].copy_from_slice(&cid.to_be_bytes());
        ping[4] = CTAPHID_PING | 0x80;
        ping[5..7].copy_from_slice(&4u16.to_be_bytes());
        ping[7..11].copy_from_slice(&[0xde, 0xad, 0xbe, 0xef]);

        let resp = server.handle_frame(&ping, &mut cb).unwrap();
        assert_eq!(resp.len(), 1);
        assert_eq!(resp[0][4], CTAPHID_PING | 0x80);
        assert_eq!(u16::from_be_bytes([resp[0][5], resp[0][6]]), 4);
        assert_eq!(&resp[0][7..11], &[0xde, 0xad, 0xbe, 0xef]);
    }

    #[test]
    fn cbor_invokes_callback_with_stripped_command_byte() {
        let mut server = UhidServer::new([0u8; 16]);
        // INIT first.
        let mut init_frame = [0u8; 64];
        init_frame[0..4].copy_from_slice(&CTAPHID_BROADCAST_CID.to_be_bytes());
        init_frame[4] = CTAPHID_INIT | 0x80;
        init_frame[5..7].copy_from_slice(&8u16.to_be_bytes());
        init_frame[7..15].copy_from_slice(&[9; 8]);
        let mut sink = vec![];
        let mut cb = |cmd: u8, payload: &[u8]| -> Vec<u8> {
            sink.push((cmd, payload.to_vec()));
            // Return CBOR success (0x00) + dummy body.
            vec![0x00, 0xaa, 0xbb]
        };
        let init_resp = server.handle_frame(&init_frame, &mut cb).unwrap();
        let cid = u32::from_be_bytes([
            init_resp[0][15],
            init_resp[0][16],
            init_resp[0][17],
            init_resp[0][18],
        ]);

        // Now CBOR: command byte 0x01 (authenticatorMakeCredential), 5-byte total.
        let mut cbor = [0u8; 64];
        cbor[0..4].copy_from_slice(&cid.to_be_bytes());
        cbor[4] = CTAPHID_CBOR | 0x80;
        cbor[5..7].copy_from_slice(&5u16.to_be_bytes());
        cbor[7..12].copy_from_slice(&[0x01, b'h', b'e', b'l', b'p']);

        let resp = server.handle_frame(&cbor, &mut cb).unwrap();
        assert_eq!(sink.len(), 1, "callback invoked exactly once");
        assert_eq!(sink[0].0, 0x01);
        assert_eq!(sink[0].1, b"help");

        assert_eq!(resp.len(), 1);
        assert_eq!(resp[0][4], CTAPHID_CBOR | 0x80);
        assert_eq!(u16::from_be_bytes([resp[0][5], resp[0][6]]), 3);
        assert_eq!(&resp[0][7..10], &[0x00, 0xaa, 0xbb]);
    }

    #[test]
    fn channel_gc_drops_idle_entries() {
        let mut table = ChannelTable::new();
        let cid = table.allocate_cid();
        table.channels.insert(
            cid,
            ChannelState {
                command: 0,
                total_len: 0,
                buffer: vec![],
                next_seq: 0,
                last_seen: Instant::now() - Duration::from_secs(60),
            },
        );
        assert!(table.channels.contains_key(&cid));
        table.gc();
        assert!(!table.channels.contains_key(&cid));
    }

    #[test]
    fn build_error_frame_is_well_formed() {
        let f = build_error_frame(0x42, ERR_INVALID_LEN);
        assert_eq!(u32::from_be_bytes([f[0], f[1], f[2], f[3]]), 0x42);
        assert_eq!(f[4], CTAPHID_ERROR | 0x80);
        assert_eq!(u16::from_be_bytes([f[5], f[6]]), 1);
        assert_eq!(f[7], ERR_INVALID_LEN);
    }

    #[test]
    fn build_keepalive_frame_carries_up_needed_status() {
        let f = build_keepalive_frame(0xa, KEEPALIVE_UP_NEEDED);
        assert_eq!(f[4], CTAPHID_KEEPALIVE | 0x80);
        assert_eq!(f[7], KEEPALIVE_UP_NEEDED);
    }

    #[test]
    fn fragment_rejects_oversized_payload() {
        let too_big = vec![0u8; MAX_PAYLOAD_LEN + 1];
        assert!(fragment_response(1, CTAPHID_CBOR, &too_big).is_err());
    }

    #[test]
    fn out_of_order_continuation_is_rejected() {
        let mut state = ChannelState::new(&InitialFrame {
            channel: 1,
            command: CTAPHID_PING,
            total_len: 100,
            payload: vec![0u8; 57],
        });
        // Expected next_seq = 0; provide 1.
        let cont = ContinuationFrame {
            channel: 1,
            sequence: 1,
            payload: vec![0u8; CONT_FRAME_PAYLOAD],
        };
        assert!(state.append(&cont).is_err());
    }
}
