//! Built-in HTTP `.avi` disguised Web Remote Desktop server.
//!
//! Runs on a dedicated TCP port (default `21120`) completely isolated from
//! RustDesk's native `21118` protocol, so existing desktop/mobile connections
//! are unaffected.
//!
//! Security model over plain HTTP (for networks that only unthrottle HTTP `.avi`):
//! - Login uses single-use random `nonce` + `HMAC-SHA256(h1, nonce)` where
//!   `h1 = SHA256(password + salt)`. The plaintext password never crosses HTTP.
//! - Both `/live.avi` video frames (after the 12-byte `RIFF....AVI ` header)
//!   and `/api/input` payloads are encrypted with per-session `ChaCha20`
//!   derived from `SHA256(h1 || nonce)`.

use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex, Once,
    },
    time::{Duration, Instant},
};

use hbb_common::{
    config::{decode_permanent_password_h1_from_storage, Config},
    log,
    message_proto::{ControlKey, KeyEvent, MouseEvent},
    rand::{self, RngCore},
    sodiumoxide::utils::memcmp,
    tokio::{
        self,
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        sync::mpsc,
    },
};
use sha2::{Digest, Sha256};

use crate::common::input::{
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_WHEEL, MOUSE_TYPE_DOWN, MOUSE_TYPE_MOVE,
    MOUSE_TYPE_MOVE_RELATIVE, MOUSE_TYPE_UP, MOUSE_TYPE_WHEEL,
};
use crate::server::input_service::{handle_key, handle_mouse};

const DEFAULT_WEB_AVI_PORT: u16 = 21120;
const WEB_CLIENT_HTML: &str = include_str!("web_client.html");
const AVI_MAGIC_HEADER: &[u8; 12] = b"RIFF\xff\xff\xff\x7fAVI ";

struct ChallengeEntry {
    created_at: Instant,
}

#[derive(Clone)]
struct WebSession {
    stream_key: [u8; 32],
    last_active: Instant,
    last_input_seq: u32,
}

#[derive(Clone)]
struct ActiveTunnel {
    tx_in: mpsc::Sender<Vec<u8>>,
    last_seq: Arc<AtomicU64>,
}

lazy_static::lazy_static! {
    static ref CHALLENGES: Mutex<HashMap<String, ChallengeEntry>> = Mutex::new(HashMap::new());
    static ref WEB_SESSIONS: Mutex<HashMap<String, WebSession>> = Mutex::new(HashMap::new());
    static ref DISPLAY_SIZE: Mutex<(i32, i32)> = Mutex::new((1920, 1080));
    static ref TUNNEL_PENDING: Mutex<HashMap<String, (Instant, TcpStream)>> = Mutex::new(HashMap::new());
    static ref TUNNEL_ACTIVE: Mutex<HashMap<String, ActiveTunnel>> = Mutex::new(HashMap::new());
}

static STARTED: Once = Once::new();
static ACTIVE_STREAMS: AtomicUsize = AtomicUsize::new(0);

/// Starts the built-in HTTP `.avi` Web Remote Desktop & tunnel server once.
pub fn start_web_avi_server(server: crate::server::ServerPtr) {
    STARTED.call_once(|| {
        tokio::spawn(async move {
            let port = Config::get_option("web-avi-port")
                .parse::<u16>()
                .ok()
                .filter(|&p| p > 0)
                .unwrap_or(DEFAULT_WEB_AVI_PORT);
            let addr = SocketAddr::from(([0, 0, 0, 0], port));
            let listener = match TcpListener::bind(addr).await {
                Ok(l) => {
                    log::info!("Web AVI server listening on http://0.0.0.0:{}", port);
                    l
                }
                Err(e) => {
                    log::warn!("Failed to bind Web AVI server on {}: {}", addr, e);
                    return;
                }
            };
            loop {
                match listener.accept().await {
                    Ok((stream, peer)) => {
                        let _ = stream.set_nodelay(true);
                        let srv = server.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_http_conn(srv, stream, peer).await {
                                log::debug!("Web AVI conn {} closed: {}", peer, e);
                            }
                        });
                    }
                    Err(e) => {
                        log::warn!("Web AVI accept error: {}", e);
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        });
    });
}

fn to_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

fn from_hex_32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    let bytes = s.as_bytes();
    for i in 0..32 {
        let hi = (bytes[i * 2] as char).to_digit(16)? as u8;
        let lo = (bytes[i * 2 + 1] as char).to_digit(16)? as u8;
        out[i] = (hi << 4) | lo;
    }
    Some(out)
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let mut h = Sha256::new();
        h.update(key);
        k_block[..32].copy_from_slice(&h.finalize());
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k_block[i];
        opad[i] ^= k_block[i];
    }
    let mut inner = Sha256::new();
    inner.update(&ipad);
    inner.update(msg);
    let inner_hash = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(&opad);
    outer.update(&inner_hash);
    let mut out = [0u8; 32];
    out.copy_from_slice(&outer.finalize());
    out
}

#[inline]
fn chacha_quarter_round(x: &mut [u32; 16], a: usize, b: usize, c: usize, d: usize) {
    x[a] = x[a].wrapping_add(x[b]);
    x[d] = (x[d] ^ x[a]).rotate_left(16);
    x[c] = x[c].wrapping_add(x[d]);
    x[b] = (x[b] ^ x[c]).rotate_left(12);
    x[a] = x[a].wrapping_add(x[b]);
    x[d] = (x[d] ^ x[a]).rotate_left(8);
    x[c] = x[c].wrapping_add(x[d]);
    x[b] = (x[b] ^ x[c]).rotate_left(7);
}

fn chacha20_xor_in_place(key: &[u8; 32], nonce: &[u8; 12], data: &mut [u8]) {
    let mut state = [0u32; 16];
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;
    for i in 0..8 {
        state[4 + i] = u32::from_le_bytes([
            key[i * 4],
            key[i * 4 + 1],
            key[i * 4 + 2],
            key[i * 4 + 3],
        ]);
    }
    state[13] = u32::from_le_bytes([nonce[0], nonce[1], nonce[2], nonce[3]]);
    state[14] = u32::from_le_bytes([nonce[4], nonce[5], nonce[6], nonce[7]]);
    state[15] = u32::from_le_bytes([nonce[8], nonce[9], nonce[10], nonce[11]]);

    let mut counter: u32 = 0;
    for chunk in data.chunks_mut(64) {
        state[12] = counter;
        counter = counter.wrapping_add(1);
        let mut w = state;
        for _ in 0..10 {
            chacha_quarter_round(&mut w, 0, 4, 8, 12);
            chacha_quarter_round(&mut w, 1, 5, 9, 13);
            chacha_quarter_round(&mut w, 2, 6, 10, 14);
            chacha_quarter_round(&mut w, 3, 7, 11, 15);
            chacha_quarter_round(&mut w, 0, 5, 10, 15);
            chacha_quarter_round(&mut w, 1, 6, 11, 12);
            chacha_quarter_round(&mut w, 2, 7, 8, 13);
            chacha_quarter_round(&mut w, 3, 4, 9, 14);
        }
        let mut ks = [0u8; 64];
        for i in 0..16 {
            let b = w[i].wrapping_add(state[i]).to_le_bytes();
            ks[i * 4..i * 4 + 4].copy_from_slice(&b);
        }
        for (dst, &k) in chunk.iter_mut().zip(ks.iter()) {
            *dst ^= k;
        }
    }
}

async fn send_http_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let header = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        status,
        content_type,
        body.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await
}

fn parse_query_param<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return Some(v);
            }
        }
    }
    None
}

async fn handle_http_conn(
    server: crate::server::ServerPtr,
    mut stream: TcpStream,
    peer: SocketAddr,
) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 2048];
    let header_end;
    loop {
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            header_end = pos + 4;
            break;
        }
        if buf.len() > 16384 {
            return send_http_response(&mut stream, "400 Bad Request", "text/plain", b"Bad Request")
                .await;
        }
    }

    let header_str = String::from_utf8_lossy(&buf[..header_end]);
    let mut lines = header_str.lines();
    let req_line = lines.next().unwrap_or("");
    let mut parts = req_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let full_target = parts.next().unwrap_or("/");
    let (path, query) = full_target.split_once('?').unwrap_or((full_target, ""));

    if method == "GET" && path == "/tunnel/down.avi" {
        return handle_tunnel_down(stream, query).await;
    }
    if method == "GET" && path.starts_with("/t/") && path.ends_with("/down.avi") {
        let sid = path.trim_start_matches("/t/").trim_end_matches("/down.avi");
        return handle_tunnel_down_sid(stream, sid).await;
    }
    if method == "POST" && path == "/tunnel/up.avi" {
        let prefix = buf[header_end..].to_vec();
        return handle_tunnel_up(server, stream, peer, query, prefix).await;
    }
    if method == "POST"
        && (path == "/api/t_up" || (path.starts_with("/t/") && path.ends_with("/up.avi")))
    {
        let sid = if path == "/api/t_up" {
            parse_query_param(query, "sid").unwrap_or("").to_owned()
        } else {
            path.trim_start_matches("/t/")
                .trim_end_matches("/up.avi")
                .to_owned()
        };
        let first_seq: u64 = parse_query_param(query, "seq")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let mut content_length: usize = 0;
        for line in lines {
            if let Some((k, v)) = line.split_once(':') {
                if k.trim().eq_ignore_ascii_case("content-length") {
                    content_length = v.trim().parse().unwrap_or(0);
                }
            }
        }
        return handle_tunnel_up_keepalive(
            server,
            stream,
            peer,
            sid,
            first_seq,
            buf[header_end..].to_vec(),
            content_length,
        )
        .await;
    }

    let mut content_length: usize = 0;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            if k.trim().eq_ignore_ascii_case("content-length") {
                content_length = v.trim().parse().unwrap_or(0);
            }
        }
    }
    if content_length > 65536 {
        return send_http_response(
            &mut stream,
            "413 Payload Too Large",
            "text/plain",
            b"Payload Too Large",
        )
        .await;
    }

    let mut body = buf[header_end..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(content_length);

    match (method, path) {
        ("GET", "/") | ("GET", "/index.html") => {
            send_http_response(
                &mut stream,
                "200 OK",
                "text/html; charset=utf-8",
                WEB_CLIENT_HTML.as_bytes(),
            )
            .await
        }
        ("GET", "/api/challenge") => handle_challenge(&mut stream).await,
        ("POST", "/api/auth") => handle_auth(&mut stream, &body).await,
        ("GET", "/live.avi") => handle_live_avi(stream, query).await,
        ("GET", p) if p.starts_with("/s/") && p.ends_with("/live.avi") => {
            handle_live_avi_path(stream, p).await
        }
        ("POST", "/api/input") => handle_input(&mut stream, query, &body).await,
        _ => {
            send_http_response(&mut stream, "404 Not Found", "text/plain", b"Not Found").await
        }
    }
}

async fn handle_tunnel_down(stream: TcpStream, query: &str) -> std::io::Result<()> {
    let sid = parse_query_param(query, "sid").unwrap_or("");
    handle_tunnel_down_sid(stream, sid).await
}

async fn handle_tunnel_down_sid(mut stream: TcpStream, sid: &str) -> std::io::Result<()> {
    if sid.len() < 8 || sid.len() > 64 {
        return send_http_response(&mut stream, "400 Bad Request", "text/plain", b"Bad sid").await;
    }
    let header = concat!(
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: video/x-msvideo\r\n",
        "Content-Length: 2147483647\r\n",
        "Accept-Ranges: bytes\r\n",
        "Cache-Control: no-store\r\n",
        "Connection: close\r\n\r\n"
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(AVI_MAGIC_HEADER).await?;
    stream.flush().await?;

    let mut map = TUNNEL_PENDING.lock().unwrap();
    let now = Instant::now();
    map.retain(|_, (t, _)| now.duration_since(*t) < Duration::from_secs(15));
    map.insert(sid.to_owned(), (now, stream));
    Ok(())
}

async fn handle_tunnel_up(
    server: crate::server::ServerPtr,
    up_stream: TcpStream,
    peer: SocketAddr,
    query: &str,
    prefix: Vec<u8>,
) -> std::io::Result<()> {
    let sid = parse_query_param(query, "sid").unwrap_or("");
    handle_tunnel_up_sid(server, up_stream, peer, sid, prefix).await
}

async fn pump_tunnel_up_stream(
    mut up_stream: TcpStream,
    sid_up: String,
    first_buf: Vec<u8>,
    first_content_len: usize,
    first_seq: u64,
    tx_in: mpsc::Sender<Vec<u8>>,
    last_seq: Arc<AtomicU64>,
) {
    let mut tmp = [0u8; 4096];
    let mut cur_len = first_content_len;
    let mut cur_seq = first_seq;
    let mut pending = first_buf;
    loop {
        if cur_len > 0 {
            while pending.len() < cur_len {
                match up_stream.read(&mut tmp).await {
                    Ok(0) => {
                        log::warn!(
                            "AVI tunnel up EOF reading body (sid={}, seq={}, got={}/{})",
                            sid_up,
                            cur_seq,
                            pending.len(),
                            cur_len
                        );
                        return;
                    }
                    Err(e) => {
                        log::warn!(
                            "AVI tunnel up read body err (sid={}, seq={}): {}",
                            sid_up,
                            cur_seq,
                            e
                        );
                        return;
                    }
                    Ok(n) => pending.extend_from_slice(&tmp[..n]),
                }
            }
            let payload = pending[..cur_len].to_vec();
            pending.drain(..cur_len);
            let prev = last_seq.load(Ordering::Acquire);
            if cur_seq == 0 || cur_seq > prev {
                if tx_in.send(payload).await.is_err() {
                    log::warn!("AVI tunnel up tx_in closed (sid={}, seq={})", sid_up, cur_seq);
                    return;
                }
                if cur_seq > prev {
                    last_seq.store(cur_seq, Ordering::Release);
                }
            }
        }
        let ok_resp = b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
        if let Err(e) = up_stream.write_all(ok_resp).await {
            log::warn!(
                "AVI tunnel up write 200 OK err (sid={}, seq={}): {}",
                sid_up,
                cur_seq,
                e
            );
            return;
        }
        // Read next keep-alive POST header
        let header_end = loop {
            if let Some(pos) = pending.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos + 4;
            }
            if pending.len() > 16384 {
                log::warn!("AVI tunnel up header too large (sid={}, seq={})", sid_up, cur_seq);
                return;
            }
            match up_stream.read(&mut tmp).await {
                Ok(0) => {
                    log::debug!(
                        "AVI tunnel up EOF waiting next POST (sid={}, seq={}, pending={})",
                        sid_up,
                        cur_seq,
                        pending.len()
                    );
                    return;
                }
                Err(e) => {
                    log::warn!(
                        "AVI tunnel up err waiting next POST (sid={}, seq={}): {}",
                        sid_up,
                        cur_seq,
                        e
                    );
                    return;
                }
                Ok(n) => pending.extend_from_slice(&tmp[..n]),
            }
        };
        let hdr = String::from_utf8_lossy(&pending[..header_end]);
        let mut hdr_lines = hdr.lines();
        let req_line = hdr_lines.next().unwrap_or("");
        let target_url = req_line.split_whitespace().nth(1).unwrap_or("");
        let query = target_url.split_once('?').map(|(_, q)| q).unwrap_or("");
        cur_seq = parse_query_param(query, "seq")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        cur_len = 0;
        for line in hdr_lines {
            if let Some((k, v)) = line.split_once(':') {
                if k.trim().eq_ignore_ascii_case("content-length") {
                    cur_len = v.trim().parse().unwrap_or(0);
                }
            }
        }
        pending.drain(..header_end);
    }
}

async fn handle_tunnel_up_keepalive(
    server: crate::server::ServerPtr,
    mut up_stream: TcpStream,
    peer: SocketAddr,
    sid: String,
    first_seq: u64,
    first_buf: Vec<u8>,
    first_content_len: usize,
) -> std::io::Result<()> {
    if sid.len() < 8 || sid.len() > 64 {
        return send_http_response(&mut up_stream, "400 Bad Request", "text/plain", b"Bad sid")
            .await;
    }

    let existing = { TUNNEL_ACTIVE.lock().unwrap().get(&sid).cloned() };
    if let Some(active) = existing {
        log::info!("AVI tunnel up reconnected for {} (sid={}, seq={})", peer, sid, first_seq);
        pump_tunnel_up_stream(
            up_stream,
            sid,
            first_buf,
            first_content_len,
            first_seq,
            active.tx_in,
            active.last_seq,
        )
        .await;
        return Ok(());
    }

    let mut down_stream = None;
    for _ in 0..150 {
        {
            let mut map = TUNNEL_PENDING.lock().unwrap();
            if let Some((_, s)) = map.remove(&sid) {
                down_stream = Some(s);
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let Some(mut down_stream) = down_stream else {
        return send_http_response(&mut up_stream, "408 Request Timeout", "text/plain", b"No down.avi")
            .await;
    };

    let (tx_in, rx_in) = mpsc::channel::<Vec<u8>>(128);
    let (tx_out, mut rx_out) = mpsc::unbounded_channel::<Vec<u8>>();
    let last_seq = Arc::new(AtomicU64::new(0));
    TUNNEL_ACTIVE.lock().unwrap().insert(
        sid.clone(),
        ActiveTunnel {
            tx_in: tx_in.clone(),
            last_seq: last_seq.clone(),
        },
    );

    // Pump downlink bytes to down.avi stream
    let sid_down = sid.clone();
    tokio::spawn(async move {
        while let Some(chunk) = rx_out.recv().await {
            if let Err(e) = down_stream.write_all(&chunk).await {
                log::warn!("AVI tunnel down.avi write closed (sid={}): {}", sid_down, e);
                break;
            }
        }
        TUNNEL_ACTIVE.lock().unwrap().remove(&sid_down);
    });

    // Keep tx_in alive as long as TUNNEL_ACTIVE holds it (until down.avi exits)
    let sid_up = sid.clone();
    tokio::spawn(async move {
        pump_tunnel_up_stream(
            up_stream,
            sid_up,
            first_buf,
            first_content_len,
            first_seq,
            tx_in,
            last_seq,
        )
        .await;
    });

    let channel_stream = crate::common::AviChannelStream::new(Vec::new(), rx_in, tx_out);
    let rustdesk_stream =
        hbb_common::Stream::Tcp(hbb_common::tcp::FramedStream::from(channel_stream, peer));
    log::info!("AVI HTTP tunnel established for {} (sid={})", peer, sid);
    hbb_common::allow_err!(
        crate::server::create_tcp_connection(server, rustdesk_stream, peer, false, None).await
    );
    TUNNEL_ACTIVE.lock().unwrap().remove(&sid);
    Ok(())
}

async fn handle_tunnel_up_sid(
    server: crate::server::ServerPtr,
    mut up_stream: TcpStream,
    peer: SocketAddr,
    sid: &str,
    prefix: Vec<u8>,
) -> std::io::Result<()> {
    if sid.len() < 8 || sid.len() > 64 {
        return send_http_response(&mut up_stream, "400 Bad Request", "text/plain", b"Bad sid")
            .await;
    }

    let mut down_stream = None;
    for _ in 0..150 {
        {
            let mut map = TUNNEL_PENDING.lock().unwrap();
            if let Some((_, s)) = map.remove(sid) {
                down_stream = Some(s);
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let Some(down_stream) = down_stream else {
        return send_http_response(&mut up_stream, "408 Request Timeout", "text/plain", b"No down.avi")
            .await;
    };

    let (up_read, _up_write) = up_stream.into_split();
    let (_down_read, down_write) = down_stream.into_split();
    let duplex = crate::common::AviDuplexStream::new(prefix, up_read, down_write);
    let rustdesk_stream =
        hbb_common::Stream::Tcp(hbb_common::tcp::FramedStream::from(duplex, peer));
    log::info!("AVI HTTP tunnel established for {} (sid={})", peer, sid);
    hbb_common::allow_err!(
        crate::server::create_tcp_connection(server, rustdesk_stream, peer, false, None).await
    );
    Ok(())
}

async fn handle_challenge(stream: &mut TcpStream) -> std::io::Result<()> {
    let mut raw = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let nonce = to_hex(&raw);
    let (storage, salt) = Config::get_local_permanent_password_storage_and_salt();
    let has_password = decode_permanent_password_h1_from_storage(&storage).is_some();

    {
        let mut map = CHALLENGES.lock().unwrap();
        let now = Instant::now();
        map.retain(|_, v| now.duration_since(v.created_at) < Duration::from_secs(60));
        if map.len() >= 64 {
            map.clear();
        }
        map.insert(nonce.clone(), ChallengeEntry { created_at: now });
    }

    let resp = serde_json::json!({
        "nonce": nonce,
        "salt": salt,
        "has_password": has_password,
    })
    .to_string();
    send_http_response(stream, "200 OK", "application/json", resp.as_bytes()).await
}

async fn handle_auth(stream: &mut TcpStream, body: &[u8]) -> std::io::Result<()> {
    #[derive(serde::Deserialize)]
    struct AuthReq {
        nonce: String,
        proof: String,
    }
    let req: AuthReq = match serde_json::from_slice(body) {
        Ok(r) => r,
        Err(_) => {
            return send_http_response(
                stream,
                "400 Bad Request",
                "application/json",
                br#"{"ok":false,"error":"invalid json"}"#,
            )
            .await;
        }
    };

    let valid_nonce = {
        let mut map = CHALLENGES.lock().unwrap();
        map.remove(&req.nonce)
            .map(|e| e.created_at.elapsed() < Duration::from_secs(60))
            .unwrap_or(false)
    };
    if !valid_nonce {
        return send_http_response(
            stream,
            "401 Unauthorized",
            "application/json",
            br#"{"ok":false,"error":"challenge expired"}"#,
        )
        .await;
    }

    let (storage, _salt) = Config::get_local_permanent_password_storage_and_salt();
    let Some(stored_h1) = decode_permanent_password_h1_from_storage(&storage) else {
        return send_http_response(
            stream,
            "403 Forbidden",
            "application/json",
            br#"{"ok":false,"error":"permanent password not set"}"#,
        )
        .await;
    };

    let expected_proof = hmac_sha256(&stored_h1, req.nonce.as_bytes());
    let Some(got_proof) = from_hex_32(&req.proof) else {
        return send_http_response(
            stream,
            "401 Unauthorized",
            "application/json",
            br#"{"ok":false,"error":"invalid proof format"}"#,
        )
        .await;
    };

    if !memcmp(&expected_proof, &got_proof) {
        return send_http_response(
            stream,
            "401 Unauthorized",
            "application/json",
            br#"{"ok":false,"error":"wrong password"}"#,
        )
        .await;
    }

    let mut sk_hasher = Sha256::new();
    sk_hasher.update(&stored_h1);
    sk_hasher.update(req.nonce.as_bytes());
    let mut stream_key = [0u8; 32];
    stream_key.copy_from_slice(&sk_hasher.finalize());

    let mut tok_raw = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut tok_raw);
    let token = to_hex(&tok_raw);

    {
        let mut sessions = WEB_SESSIONS.lock().unwrap();
        let now = Instant::now();
        sessions.retain(|_, s| now.duration_since(s.last_active) < Duration::from_secs(3600));
        if sessions.len() >= 16 {
            sessions.clear();
        }
        sessions.insert(
            token.clone(),
            WebSession {
                stream_key,
                last_active: now,
                last_input_seq: 0,
            },
        );
    }

    let resp = serde_json::json!({
        "ok": true,
        "token": token,
    })
    .to_string();
    send_http_response(stream, "200 OK", "application/json", resp.as_bytes()).await
}

fn get_session_key(token: &str) -> Option<[u8; 32]> {
    let mut sessions = WEB_SESSIONS.lock().unwrap();
    if let Some(s) = sessions.get_mut(token) {
        s.last_active = Instant::now();
        return Some(s.stream_key);
    }
    None
}

async fn write_http_chunk(stream: &mut TcpStream, data: &[u8]) -> std::io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    let prefix = format!("{:x}\r\n", data.len());
    stream.write_all(prefix.as_bytes()).await?;
    stream.write_all(data).await?;
    stream.write_all(b"\r\n").await
}

async fn handle_live_avi_path(stream: TcpStream, path: &str) -> std::io::Result<()> {
    let segs: Vec<&str> = path.trim_matches('/').split('/').collect();
    if segs.len() < 7 {
        return handle_live_avi_params(stream, "", 30, 70, 0.75, true).await;
    }
    let token = segs[1];
    let fps: u64 = segs[2].parse().unwrap_or(30).clamp(5, 60);
    let quality: u8 = segs[3].parse().unwrap_or(70).clamp(25, 95);
    let scale: f32 = segs[4].parse().unwrap_or(0.75f32).clamp(0.25, 1.0);
    let show_cursor: bool = segs[5] != "0";
    handle_live_avi_params(stream, token, fps, quality, scale, show_cursor).await
}

async fn handle_live_avi(stream: TcpStream, query: &str) -> std::io::Result<()> {
    let token = parse_query_param(query, "token").unwrap_or("");
    let fps: u64 = parse_query_param(query, "fps")
        .and_then(|v| v.parse().ok())
        .unwrap_or(30)
        .clamp(5, 60);
    let quality: u8 = parse_query_param(query, "q")
        .and_then(|v| v.parse().ok())
        .unwrap_or(70)
        .clamp(25, 95);
    let scale: f32 = parse_query_param(query, "s")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.75f32)
        .clamp(0.25, 1.0);
    let show_cursor: bool = parse_query_param(query, "cursor").unwrap_or("1") != "0";
    handle_live_avi_params(stream, token, fps, quality, scale, show_cursor).await
}

async fn handle_live_avi_params(
    mut stream: TcpStream,
    token: &str,
    fps: u64,
    quality: u8,
    scale: f32,
    show_cursor: bool,
) -> std::io::Result<()> {
    let Some(stream_key) = get_session_key(token) else {
        return send_http_response(
            &mut stream,
            "401 Unauthorized",
            "text/plain",
            b"Unauthorized",
        )
        .await;
    };

    let header = concat!(
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: video/x-msvideo\r\n",
        "Content-Length: 2147483647\r\n",
        "Accept-Ranges: bytes\r\n",
        "Cache-Control: no-cache, no-store, must-revalidate\r\n",
        "Connection: close\r\n\r\n"
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(AVI_MAGIC_HEADER).await?;

    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(2);
    let stop_flag = Arc::new(AtomicBool::new(false));
    let stop_clone = stop_flag.clone();

    ACTIVE_STREAMS.fetch_add(1, Ordering::SeqCst);
    std::thread::spawn(move || {
        capture_loop(fps, quality, scale, show_cursor, stream_key, tx, stop_clone);
    });

    while let Some(pkt) = rx.recv().await {
        if stream.write_all(&pkt).await.is_err() {
            break;
        }
    }

    stop_flag.store(true, Ordering::SeqCst);
    ACTIVE_STREAMS.fetch_sub(1, Ordering::SeqCst);
    Ok(())
}

fn fast_sample_hash(bgra: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    let step = (bgra.len() / 2048).max(4) & !3;
    let mut i = 0;
    while i + 3 < bgra.len() {
        let v = u32::from_le_bytes([bgra[i], bgra[i + 1], bgra[i + 2], bgra[i + 3]]) as u64;
        h ^= v;
        h = h.wrapping_mul(0x100000001b3);
        i += step;
    }
    h
}

fn draw_cursor_on_rgb(rgb: &mut [u8], w: usize, h: usize, cx: i32, cy: i32) {
    // Classic 12x18 arrow cursor bitmap: '.' = transparent, '#' = black border, 'W' = white fill
    const CURSOR: &[&[u8]] = &[
        b"#...........",
        b"##..........",
        b"#W#.........",
        b"#WW#........",
        b"#WWW#.......",
        b"#WWWW#......",
        b"#WWWWW#.....",
        b"#WWWWWW#....",
        b"#WWWWWWW#...",
        b"#WWWWWWWW#..",
        b"#WWWWWWWWW#.",
        b"#WWWWWW#####",
        b"#WWW#WW#....",
        b"#WW#.#WW#...",
        b"#W#..#WW#...",
        b"##....#WW#..",
        b"#.....#WW#..",
        b".......##...",
    ];
    for (dy, row) in CURSOR.iter().enumerate() {
        let py = cy + dy as i32;
        if py < 0 || py >= h as i32 {
            continue;
        }
        for (dx, &ch) in row.iter().enumerate() {
            if ch == b'.' {
                continue;
            }
            let px = cx + dx as i32;
            if px < 0 || px >= w as i32 {
                continue;
            }
            let off = (py as usize * w + px as usize) * 3;
            if off + 2 < rgb.len() {
                let c = if ch == b'W' { 255u8 } else { 0u8 };
                rgb[off] = c;
                rgb[off + 1] = c;
                rgb[off + 2] = c;
            }
        }
    }
}

fn capture_loop(
    fps: u64,
    quality: u8,
    scale: f32,
    show_cursor: bool,
    stream_key: [u8; 32],
    tx: mpsc::Sender<Vec<u8>>,
    stop: Arc<AtomicBool>,
) {
    use scrap::{TraitCapturer, TraitPixelBuffer};
    let mut displays = match scrap::Display::all() {
        Ok(d) => d,
        Err(e) => {
            log::warn!("Web AVI Display::all failed: {}", e);
            return;
        }
    };
    if displays.is_empty() {
        log::warn!("Web AVI Display::all returned 0 displays");
        return;
    }
    let idx = displays.iter().position(|d| d.is_primary()).unwrap_or(0);
    let display = displays.remove(idx);
    let disp_w = display.width() as i32;
    let disp_h = display.height() as i32;
    let (disp_ox, disp_oy) = display.origin();
    *DISPLAY_SIZE.lock().unwrap() = (disp_w, disp_h);

    let mut capturer = match scrap::Capturer::new(display) {
        Ok(c) => c,
        Err(e) => {
            log::warn!("Web AVI Capturer::new failed: {}", e);
            return;
        }
    };

    let interval = Duration::from_millis((1000 / fps).max(10));
    let mut last_hash: u64 = 0;
    let mut last_sent = Instant::now() - Duration::from_secs(10);
    let mut seq: u32 = 1;
    let mut rgb_buf: Vec<u8> = Vec::new();
    let mut jpg_buf: Vec<u8> = Vec::new();

    while !stop.load(Ordering::SeqCst) {
        let frame_start = Instant::now();
        match capturer.frame(interval) {
            Ok(frame) if frame.valid() => {
                let scrap::Frame::PixelBuffer(pixbuf) = frame else {
                    continue;
                };
                let w = pixbuf.width();
                let h = pixbuf.height();
                let Some(&stride) = pixbuf.stride().first() else {
                    continue;
                };
                if w == 0 || h == 0 || stride < w * 4 {
                    continue;
                }
                let bgra = pixbuf.data();
                let cursor_pos = if show_cursor { crate::get_cursor_pos() } else { None };
                let mut cur_hash = fast_sample_hash(bgra);
                if let Some((cx, cy)) = cursor_pos {
                    cur_hash ^= ((cx as u64) << 32) ^ (cy as u64 & 0xffff_ffff);
                }
                let unchanged = cur_hash == last_hash && last_sent.elapsed() < Duration::from_secs(2);
                if unchanged {
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                if cur_hash == last_hash {
                    // Send keepalive packet
                    let mut ka = Vec::with_capacity(12);
                    ka.extend_from_slice(&0u16.to_le_bytes());
                    ka.extend_from_slice(&0u16.to_le_bytes());
                    ka.extend_from_slice(&0u32.to_le_bytes());
                    ka.extend_from_slice(&seq.to_le_bytes());
                    seq = seq.wrapping_add(1);
                    last_sent = Instant::now();
                    if tx.blocking_send(ka).is_err() {
                        break;
                    }
                    continue;
                }

                last_hash = cur_hash;
                let out_w = ((w as f32 * scale).round() as usize).max(160).min(w);
                let out_h = ((h as f32 * scale).round() as usize).max(90).min(h);
                rgb_buf.resize(out_w * out_h * 3, 0);

                for dy in 0..out_h {
                    let sy = (dy * h) / out_h;
                    let row_off = sy * stride;
                    let dst_row = dy * out_w * 3;
                    for dx in 0..out_w {
                        let sx = (dx * w) / out_w;
                        let s_off = row_off + sx * 4;
                        let d_off = dst_row + dx * 3;
                        rgb_buf[d_off] = bgra[s_off + 2];
                        rgb_buf[d_off + 1] = bgra[s_off + 1];
                        rgb_buf[d_off + 2] = bgra[s_off];
                    }
                }

                if let Some((cx, cy)) = cursor_pos {
                    let rx = ((cx - disp_ox) as isize * out_w as isize / w as isize) as i32;
                    let ry = ((cy - disp_oy) as isize * out_h as isize / h as isize) as i32;
                    draw_cursor_on_rgb(&mut rgb_buf, out_w, out_h, rx, ry);
                }

                jpg_buf.clear();
                let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpg_buf, quality);
                if enc
                    .encode(&rgb_buf, out_w as u32, out_h as u32, image::ColorType::Rgb8)
                    .is_err()
                {
                    continue;
                }

                let mut nonce = [0u8; 12];
                nonce[0..4].copy_from_slice(&seq.to_le_bytes());
                chacha20_xor_in_place(&stream_key, &nonce, &mut jpg_buf);

                let mut pkt = Vec::with_capacity(12 + jpg_buf.len());
                pkt.extend_from_slice(&(out_w as u16).to_le_bytes());
                pkt.extend_from_slice(&(out_h as u16).to_le_bytes());
                pkt.extend_from_slice(&(jpg_buf.len() as u32).to_le_bytes());
                pkt.extend_from_slice(&seq.to_le_bytes());
                pkt.extend_from_slice(&jpg_buf);
                seq = seq.wrapping_add(1);
                last_sent = Instant::now();

                if tx.blocking_send(pkt).is_err() {
                    break;
                }
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => {
                log::warn!("Web AVI capture error: {}", e);
                std::thread::sleep(Duration::from_millis(200));
            }
        }
        let elapsed = frame_start.elapsed();
        if elapsed < interval {
            std::thread::sleep(interval - elapsed);
        }
    }
}

async fn handle_input(stream: &mut TcpStream, query: &str, body: &[u8]) -> std::io::Result<()> {
    let token = parse_query_param(query, "token").unwrap_or("");
    if body.len() < 4 {
        return send_http_response(stream, "400 Bad Request", "text/plain", b"Bad input").await;
    }
    let seq = u32::from_le_bytes([body[0], body[1], body[2], body[3]]);

    enum InputAuth {
        Ok([u8; 32]),
        Unauthorized,
        Replay,
    }
    let auth_res = {
        let mut sessions = WEB_SESSIONS.lock().unwrap();
        match sessions.get_mut(token) {
            None => InputAuth::Unauthorized,
            Some(s) if seq <= s.last_input_seq => InputAuth::Replay,
            Some(s) => {
                s.last_input_seq = seq;
                s.last_active = Instant::now();
                InputAuth::Ok(s.stream_key)
            }
        }
    };
    let stream_key = match auth_res {
        InputAuth::Ok(k) => k,
        InputAuth::Unauthorized => {
            return send_http_response(stream, "401 Unauthorized", "text/plain", b"Unauthorized")
                .await;
        }
        InputAuth::Replay => {
            return send_http_response(stream, "403 Forbidden", "text/plain", b"Replay").await;
        }
    };

    let mut plain = body[4..].to_vec();
    let mut nonce = [0u8; 12];
    nonce[0..4].copy_from_slice(&seq.to_le_bytes());
    nonce[11] = 0x5A;
    chacha20_xor_in_place(&stream_key, &nonce, &mut plain);

    let Ok(val) = serde_json::from_slice::<serde_json::Value>(&plain) else {
        return send_http_response(stream, "400 Bad Request", "text/plain", b"Bad JSON").await;
    };

    dispatch_web_input(&val);
    send_http_response(stream, "200 OK", "application/json", br#"{"ok":true}"#).await
}

fn dispatch_web_input(val: &serde_json::Value) {
    let typ = val.get("type").and_then(|v| v.as_str()).unwrap_or("");
    let (dw, dh) = *DISPLAY_SIZE.lock().unwrap();

    match typ {
        "move_rel" => {
            let dx = val.get("dx").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let dy = val.get("dy").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            if dx != 0 || dy != 0 {
                let mut evt = MouseEvent::new();
                evt.mask = MOUSE_TYPE_MOVE_RELATIVE;
                evt.x = dx.clamp(-2000, 2000);
                evt.y = dy.clamp(-2000, 2000);
                handle_mouse(&evt, 0, "web".to_owned(), 0, true, false);
            }
        }
        "move" | "down" | "up" => {
            if let (Some(nx), Some(ny)) = (
                val.get("x").and_then(|v| v.as_f64()),
                val.get("y").and_then(|v| v.as_f64()),
            ) {
                let px = (nx.clamp(0.0, 1.0) * dw as f64).round() as i32;
                let py = (ny.clamp(0.0, 1.0) * dh as f64).round() as i32;
                if typ == "move" || typ == "down" {
                    let mut move_evt = MouseEvent::new();
                    move_evt.mask = MOUSE_TYPE_MOVE;
                    move_evt.x = px;
                    move_evt.y = py;
                    handle_mouse(&move_evt, 0, "web".to_owned(), 0, true, false);
                }
            }
            if typ == "down" || typ == "up" {
                let btn = match val.get("button").and_then(|v| v.as_str()).unwrap_or("left") {
                    "right" => MOUSE_BUTTON_RIGHT,
                    "middle" => MOUSE_BUTTON_WHEEL,
                    _ => MOUSE_BUTTON_LEFT,
                };
                let mask = if typ == "down" {
                    (btn << 3) | MOUSE_TYPE_DOWN
                } else {
                    (btn << 3) | MOUSE_TYPE_UP
                };
                let mut evt = MouseEvent::new();
                evt.mask = mask;
                handle_mouse(&evt, 0, "web".to_owned(), 0, true, false);
            }
        }
        "wheel" => {
            let dx = val.get("dx").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let dy = val.get("dy").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let mut evt = MouseEvent::new();
            evt.mask = MOUSE_TYPE_WHEEL;
            evt.x = dx.clamp(-120, 120);
            evt.y = dy.clamp(-120, 120);
            handle_mouse(&evt, 0, "web".to_owned(), 0, true, false);
        }
        "text" => {
            if let Some(txt) = val.get("text").and_then(|v| v.as_str()) {
                for ch in txt.chars() {
                    let mut evt = KeyEvent::new();
                    evt.press = true;
                    evt.set_unicode(ch as u32);
                    handle_key(&evt);
                }
            }
        }
        "key" => {
            let code = val.get("code").and_then(|v| v.as_str()).unwrap_or("");
            let key = val.get("key").and_then(|v| v.as_str()).unwrap_or("");
            let down = val.get("down").and_then(|v| v.as_bool()).unwrap_or(false);
            let mut evt = KeyEvent::new();
            evt.down = down;
            if let Some(ck) = map_dom_control_key(code) {
                evt.set_control_key(ck);
                handle_key(&evt);
            } else if key.chars().count() == 1 {
                if let Some(ch) = key.chars().next() {
                    evt.set_chr(ch as u32);
                    handle_key(&evt);
                }
            }
        }
        _ => {}
    }
}

fn map_dom_control_key(code: &str) -> Option<ControlKey> {
    Some(match code {
        "Escape" => ControlKey::Escape,
        "Enter" | "NumpadEnter" => ControlKey::Return,
        "Backspace" => ControlKey::Backspace,
        "Tab" => ControlKey::Tab,
        "Space" => ControlKey::Space,
        "Delete" => ControlKey::Delete,
        "Insert" => ControlKey::Insert,
        "Home" => ControlKey::Home,
        "End" => ControlKey::End,
        "PageUp" => ControlKey::PageUp,
        "PageDown" => ControlKey::PageDown,
        "ArrowUp" => ControlKey::UpArrow,
        "ArrowDown" => ControlKey::DownArrow,
        "ArrowLeft" => ControlKey::LeftArrow,
        "ArrowRight" => ControlKey::RightArrow,
        "ShiftLeft" => ControlKey::Shift,
        "ShiftRight" => ControlKey::RShift,
        "ControlLeft" => ControlKey::Control,
        "ControlRight" => ControlKey::RControl,
        "AltLeft" => ControlKey::Alt,
        "AltRight" => ControlKey::RAlt,
        "MetaLeft" => ControlKey::Meta,
        "MetaRight" => ControlKey::RWin,
        "CapsLock" => ControlKey::CapsLock,
        "F1" => ControlKey::F1,
        "F2" => ControlKey::F2,
        "F3" => ControlKey::F3,
        "F4" => ControlKey::F4,
        "F5" => ControlKey::F5,
        "F6" => ControlKey::F6,
        "F7" => ControlKey::F7,
        "F8" => ControlKey::F8,
        "F9" => ControlKey::F9,
        "F10" => ControlKey::F10,
        "F11" => ControlKey::F11,
        "F12" => ControlKey::F12,
        _ => return None,
    })
}
