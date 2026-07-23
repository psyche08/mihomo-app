use crate::app_log;
use serde_json::json;
use std::fs::File;
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

const MAXIMUM_CONNECTIONS: usize = 32;

struct ConnectionLimiter {
    active: AtomicUsize,
    maximum: usize,
}

impl ConnectionLimiter {
    fn new(maximum: usize) -> Arc<Self> {
        Arc::new(Self {
            active: AtomicUsize::new(0),
            maximum: maximum.max(1),
        })
    }

    fn try_acquire(self: &Arc<Self>) -> Option<ConnectionPermit> {
        let mut active = self.active.load(Ordering::Acquire);
        loop {
            if active >= self.maximum {
                return None;
            }
            match self.active.compare_exchange_weak(
                active,
                active + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    return Some(ConnectionPermit {
                        limiter: self.clone(),
                    });
                }
                Err(observed) => active = observed,
            }
        }
    }
}

struct ConnectionPermit {
    limiter: Arc<ConnectionLimiter>,
}

impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.limiter.active.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Clone, Debug)]
pub struct DashboardBridge {
    pub url: String,
    pub secret: String,
}

impl DashboardBridge {
    pub fn start(cli: &Path) -> Option<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").ok()?;
        let address = listener.local_addr().ok()?;
        let secret = random_secret()?;
        let worker_secret = secret.clone();
        let cli = cli.to_path_buf();
        let limiter = ConnectionLimiter::new(MAXIMUM_CONNECTIONS);
        thread::Builder::new()
            .name("mihomobox-dashboard-xpc-bridge".to_string())
            .spawn(move || {
                for incoming in listener.incoming() {
                    let Ok(stream) = incoming else {
                        thread::sleep(Duration::from_millis(100));
                        continue;
                    };
                    let Some(permit) = limiter.try_acquire() else {
                        app_log::error("event=dashboard_request result=connection_limit");
                        continue;
                    };
                    let cli = cli.clone();
                    let secret = worker_secret.clone();
                    let _ = thread::Builder::new()
                        .name("mihomobox-dashboard-request".to_string())
                        .spawn(move || {
                            let _permit = permit;
                            handle(stream, &cli, &secret);
                        });
                }
            })
            .ok()?;
        app_log::info("event=dashboard_bridge result=started");
        Some(Self {
            url: format!("http://127.0.0.1:{}", address.port()),
            secret,
        })
    }
}

struct Request {
    method: String,
    target: String,
    authorization: Option<String>,
    websocket_key: Option<String>,
    websocket_upgrade: bool,
    body: Vec<u8>,
}

fn handle(mut stream: TcpStream, cli: &Path, secret: &str) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(40)));
    let Some(request) = read_request(&mut stream) else {
        return;
    };
    if request.method == "OPTIONS" {
        app_log::info("event=dashboard_request kind=preflight result=success");
        write_response(&mut stream, 204, &[]);
        return;
    }
    let authorized = request.authorization.as_deref() == Some(&format!("Bearer {secret}"))
        || query_value(&request.target, "token").as_deref() == Some(secret);
    if !authorized {
        app_log::error("event=dashboard_request result=unauthorized");
        write_json_error(&mut stream, 401, "unauthorized");
        return;
    }

    if request.websocket_upgrade {
        let Some(key) = request.websocket_key else {
            app_log::error("event=dashboard_request kind=websocket result=invalid_key");
            write_json_error(&mut stream, 400, "missing WebSocket key");
            return;
        };
        app_log::info("event=dashboard_request kind=websocket phase=started");
        proxy_websocket(&mut stream, cli, &request.target, &key);
        return;
    }

    match route_http(cli, &request) {
        Ok(body) => {
            app_log::info("event=dashboard_request kind=http result=success");
            write_response(&mut stream, 200, &body)
        }
        Err((status, message)) => {
            app_log::error("event=dashboard_request kind=http result=failed");
            write_json_error(&mut stream, status, message)
        }
    }
}

fn route_http(cli: &Path, request: &Request) -> Result<Vec<u8>, (u16, &'static str)> {
    let path = request.target.split('?').next().unwrap_or("/");
    match (request.method.as_str(), path) {
        ("PUT", "/configs") if !has_inline_config_payload(&request.body) => {
            invoke(cli, &["profile", "reload"], None)
        }
        ("POST", "/restart") => invoke(cli, &["restart"], None),
        ("POST", "/upgrade") | ("POST", "/upgrade/ui") => Err((
            403,
            "managed binaries and UI are upgraded only by a signed MihomoBox release",
        )),
        _ => invoke(
            cli,
            &["rpc", "controller", &request.method, &request.target],
            Some(&request.body),
        ),
    }
}

fn has_inline_config_payload(body: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|value| value.get("payload")?.as_str().map(str::to_owned))
        .is_some_and(|payload| !payload.is_empty())
}

fn invoke(
    cli: &Path,
    arguments: &[&str],
    body: Option<&[u8]>,
) -> Result<Vec<u8>, (u16, &'static str)> {
    let mut child = Command::new(cli)
        .args(arguments)
        .stdin(if body.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| (503, "XPC helper unavailable"))?;
    if let Some(body) = body {
        let Some(mut input) = child.stdin.take() else {
            return Err((503, "XPC helper input unavailable"));
        };
        input
            .write_all(body)
            .map_err(|_| (503, "XPC helper input failed"))?;
    }
    let output = child
        .wait_with_output()
        .map_err(|_| (503, "XPC helper failed"))?;
    if !output.status.success() {
        return Err((503, "XPC operation failed"));
    }
    if output.stdout.is_empty() {
        Ok(b"{}".to_vec())
    } else {
        Ok(output.stdout)
    }
}

fn proxy_websocket(stream: &mut TcpStream, cli: &Path, target: &str, key: &str) {
    let accept = websocket_accept(key);
    let response = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    if stream.write_all(response.as_bytes()).is_err() {
        return;
    }
    let _ = stream.set_read_timeout(Some(Duration::from_millis(1)));

    loop {
        if client_closed(stream) {
            return;
        }
        match invoke(cli, &["rpc", "stream", target], None) {
            Ok(message) if send_websocket_frame(stream, 0x1, &message).is_ok() => {}
            _ => {
                let _ = send_websocket_frame(stream, 0x8, &1011_u16.to_be_bytes());
                return;
            }
        }
    }
}

fn client_closed(stream: &mut TcpStream) -> bool {
    let _ = stream.set_nonblocking(true);
    let mut value = [0_u8; 2];
    let closed = match stream.peek(&mut value) {
        Ok(0) => true,
        Ok(_) => value[0] & 0x0f == 0x8,
        Err(error) if error.kind() == ErrorKind::WouldBlock => false,
        Err(_) => true,
    };
    let _ = stream.set_nonblocking(false);
    closed
}

fn send_websocket_frame(stream: &mut TcpStream, opcode: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut header = vec![0x80 | (opcode & 0x0f)];
    match payload.len() {
        length @ 0..=125 => header.push(length as u8),
        length @ 126..=65_535 => {
            header.push(126);
            header.extend_from_slice(&(length as u16).to_be_bytes());
        }
        length => {
            header.push(127);
            header.extend_from_slice(&(length as u64).to_be_bytes());
        }
    }
    stream.write_all(&header)?;
    stream.write_all(payload)
}

fn read_request(stream: &mut TcpStream) -> Option<Request> {
    const LIMIT: usize = 1024 * 1024;
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 8192];
    let header_end = loop {
        let count = stream.read(&mut buffer).ok()?;
        if count == 0 || bytes.len() + count > LIMIT {
            return None;
        }
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(position) = bytes.windows(4).position(|value| value == b"\r\n\r\n") {
            break position + 4;
        }
    };
    let headers = std::str::from_utf8(&bytes[..header_end]).ok()?;
    let mut lines = headers.split("\r\n");
    let mut request_line = lines.next()?.split_whitespace();
    let method = request_line.next()?.to_string();
    let target = request_line.next()?.to_string();
    let mut authorization = None;
    let mut websocket_key = None;
    let mut websocket_upgrade = false;
    let mut content_length = 0_usize;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("authorization") {
            authorization = Some(value.to_string());
        } else if name.eq_ignore_ascii_case("content-length") {
            content_length = value.parse().ok()?;
        } else if name.eq_ignore_ascii_case("sec-websocket-key") {
            websocket_key = Some(value.to_string());
        } else if name.eq_ignore_ascii_case("upgrade") && value.eq_ignore_ascii_case("websocket") {
            websocket_upgrade = true;
        }
    }
    if header_end + content_length > LIMIT {
        return None;
    }
    while bytes.len() < header_end + content_length {
        let count = stream.read(&mut buffer).ok()?;
        if count == 0 || bytes.len() + count > LIMIT {
            return None;
        }
        bytes.extend_from_slice(&buffer[..count]);
    }
    Some(Request {
        method,
        target,
        authorization,
        websocket_key,
        websocket_upgrade,
        body: bytes[header_end..header_end + content_length].to_vec(),
    })
}

fn write_json_error(stream: &mut TcpStream, status: u16, message: &str) {
    let body = serde_json::to_vec(&json!({"error":message})).unwrap_or_default();
    write_response(stream, status, &body);
}

fn write_response(stream: &mut TcpStream, status: u16, body: &[u8]) {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "Error",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Methods: GET, PUT, PATCH, POST, DELETE, OPTIONS\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(header.as_bytes());
    let _ = stream.write_all(body);
}

fn query_value(target: &str, name: &str) -> Option<String> {
    target.split_once('?')?.1.split('&').find_map(|item| {
        let (key, value) = item.split_once('=')?;
        (key == name).then(|| value.to_string())
    })
}

fn websocket_accept(key: &str) -> String {
    let mut value = key.as_bytes().to_vec();
    value.extend_from_slice(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    base64_encode(&sha1(&value))
}

fn sha1(data: &[u8]) -> [u8; 20] {
    let bit_length = (data.len() as u64) * 8;
    let mut padded = data.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_length.to_be_bytes());

    let mut state = [
        0x67452301_u32,
        0xefcdab89,
        0x98badcfe,
        0x10325476,
        0xc3d2e1f0,
    ];
    for chunk in padded.chunks_exact(64) {
        let mut words = [0_u32; 80];
        for (index, word) in words.iter_mut().take(16).enumerate() {
            let start = index * 4;
            *word = u32::from_be_bytes(chunk[start..start + 4].try_into().expect("word"));
        }
        for index in 16..80 {
            words[index] =
                (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16])
                    .rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = state;
        for (index, word) in words.iter().enumerate() {
            let (function, constant) = match index {
                0..=19 => ((b & c) | ((!b) & d), 0x5a827999),
                20..=39 => (b ^ c ^ d, 0x6ed9eba1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8f1bbcdc),
                _ => (b ^ c ^ d, 0xca62c1d6),
            };
            let next = a
                .rotate_left(5)
                .wrapping_add(function)
                .wrapping_add(e)
                .wrapping_add(constant)
                .wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = next;
        }
        state[0] = state[0].wrapping_add(a);
        state[1] = state[1].wrapping_add(b);
        state[2] = state[2].wrapping_add(c);
        state[3] = state[3].wrapping_add(d);
        state[4] = state[4].wrapping_add(e);
    }

    let mut digest = [0_u8; 20];
    for (index, value) in state.iter().enumerate() {
        digest[index * 4..index * 4 + 4].copy_from_slice(&value.to_be_bytes());
    }
    digest
}

fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let value = ((chunk[0] as u32) << 16)
            | ((chunk.get(1).copied().unwrap_or(0) as u32) << 8)
            | chunk.get(2).copied().unwrap_or(0) as u32;
        output.push(TABLE[((value >> 18) & 0x3f) as usize] as char);
        output.push(TABLE[((value >> 12) & 0x3f) as usize] as char);
        output.push(if chunk.len() > 1 {
            TABLE[((value >> 6) & 0x3f) as usize] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            TABLE[(value & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    output
}

fn random_secret() -> Option<String> {
    let mut bytes = [0_u8; 32];
    File::open("/dev/urandom")
        .ok()?
        .read_exact(&mut bytes)
        .ok()?;
    Some(bytes.iter().map(|value| format!("{value:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn websocket_accept_matches_rfc_example() {
        assert_eq!(
            websocket_accept("dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        );
    }

    #[test]
    fn query_token_is_extracted_without_exposing_other_values() {
        assert_eq!(
            query_value("/logs?level=info&token=abc123", "token").as_deref(),
            Some("abc123")
        );
    }

    #[test]
    fn inline_config_payload_is_distinct_from_managed_profile_reload() {
        assert!(!has_inline_config_payload(br#"{"path":"","payload":""}"#));
        assert!(has_inline_config_payload(
            br#"{"path":"","payload":"mode: rule\n"}"#
        ));
    }

    #[test]
    fn connection_limiter_releases_capacity() {
        let limiter = ConnectionLimiter::new(2);
        let first = limiter.try_acquire().expect("first permit");
        let second = limiter.try_acquire().expect("second permit");
        assert!(limiter.try_acquire().is_none());
        drop(first);
        assert!(limiter.try_acquire().is_some());
        drop(second);
    }
}
