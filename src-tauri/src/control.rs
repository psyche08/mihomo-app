//! Direct XPC control channel to the root daemon.
//!
//! Every request used to spawn `mihomoboxctl`. Measured on an M4 Pro, that was
//! ~6 ms of process start plus ~22 ms of building the code-signing requirement
//! and validating the peer, on every call — a fresh process reloads
//! Security.framework's certificate parser each time, and the tray polls every
//! five seconds. One retained connection pays that once.
//!
//! The privilege boundary is unchanged. This speaks the same protocol over the
//! same privileged Mach service, and the daemon still admits a peer only if it
//! carries the same signing leaf, so an unsigned or differently signed build
//! cannot talk to it.

use serde::{Deserialize, Serialize};
use std::os::raw::{c_int, c_uchar};
use std::sync::{Mutex, OnceLock};

#[repr(C)]
struct Session {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn mihomo_control_open(out_error: *mut c_int) -> *mut Session;
    fn mihomo_control_close(session: *mut Session);
    fn mihomo_control_send(
        session: *mut Session,
        request: *const c_uchar,
        request_length: usize,
        payload: *const c_uchar,
        payload_length: usize,
        out_response: *mut *mut c_uchar,
        out_response_length: *mut usize,
        out_payload: *mut *mut c_uchar,
        out_payload_length: *mut usize,
    ) -> c_int;
    fn mihomo_control_free(buffer: *mut c_uchar);
}

const PROTOCOL_VERSION: i32 = 1;

#[derive(Serialize)]
struct ControlRequest<'a> {
    version: i32,
    operation: &'a str,
    arguments: &'a std::collections::BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct ControlResponse {
    version: i32,
    success: bool,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug)]
pub enum ControlError {
    /// The daemon could not be reached, or the connection went away.
    Unavailable,
    /// The daemon answered and refused.
    Rejected(String),
    /// The reply did not match the protocol.
    Invalid,
}

/// The retained connection.
///
/// `xpc_connection_send_message_with_reply_sync` is safe to call concurrently,
/// but the handle is replaced on failure, so it sits behind a mutex: a caller
/// that finds a dead connection drops it and the next call reopens.
struct Channel(*mut Session);

// Safety: the pointer is only ever used behind the mutex below, and the XPC
// connection it wraps is itself thread-safe.
unsafe impl Send for Channel {}

impl Drop for Channel {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { mihomo_control_close(self.0) };
        }
    }
}

fn channel() -> &'static Mutex<Option<Channel>> {
    static CHANNEL: OnceLock<Mutex<Option<Channel>>> = OnceLock::new();
    CHANNEL.get_or_init(|| Mutex::new(None))
}

/// Sends one control request, reconnecting once if the retained connection has
/// gone away — which it does whenever the daemon restarts, including on every
/// component upgrade.
pub fn send(
    operation: &str,
    arguments: &std::collections::BTreeMap<String, String>,
    payload: Option<&[u8]>,
) -> Result<Vec<u8>, ControlError> {
    let encoded = serde_json::to_vec(&ControlRequest {
        version: PROTOCOL_VERSION,
        operation,
        arguments,
    })
    .map_err(|_| ControlError::Invalid)?;

    let mut guard = channel().lock().map_err(|_| ControlError::Unavailable)?;
    for attempt in 0..2 {
        if guard.is_none() {
            let mut error: c_int = 0;
            let session = unsafe { mihomo_control_open(&mut error) };
            if session.is_null() {
                return Err(ControlError::Unavailable);
            }
            *guard = Some(Channel(session));
        }
        let session = guard.as_ref().expect("channel present").0;

        let mut response: *mut c_uchar = std::ptr::null_mut();
        let mut response_length: usize = 0;
        let mut reply_payload: *mut c_uchar = std::ptr::null_mut();
        let mut reply_payload_length: usize = 0;
        let status = unsafe {
            mihomo_control_send(
                session,
                encoded.as_ptr(),
                encoded.len(),
                payload.map_or(std::ptr::null(), <[u8]>::as_ptr),
                payload.map_or(0, <[u8]>::len),
                &mut response,
                &mut response_length,
                &mut reply_payload,
                &mut reply_payload_length,
            )
        };
        if status != 0 {
            // Drop the connection and try once more: the common cause is the
            // daemon having restarted under us.
            *guard = None;
            if attempt == 0 {
                continue;
            }
            return Err(ControlError::Unavailable);
        }

        let decoded = unsafe { std::slice::from_raw_parts(response, response_length) }.to_vec();
        unsafe { mihomo_control_free(response) };
        let payload_out = if reply_payload.is_null() {
            Vec::new()
        } else {
            let bytes =
                unsafe { std::slice::from_raw_parts(reply_payload, reply_payload_length) }.to_vec();
            unsafe { mihomo_control_free(reply_payload) };
            bytes
        };

        let parsed: ControlResponse =
            serde_json::from_slice(&decoded).map_err(|_| ControlError::Invalid)?;
        if parsed.version != PROTOCOL_VERSION {
            return Err(ControlError::Invalid);
        }
        if !parsed.success {
            return Err(ControlError::Rejected(
                parsed
                    .error
                    .unwrap_or_else(|| "request rejected".to_string()),
            ));
        }
        return Ok(payload_out);
    }
    Err(ControlError::Unavailable)
}
