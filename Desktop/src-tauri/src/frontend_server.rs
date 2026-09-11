//! Serves `Desktop/dist` from 127.0.0.1 so WebView2 does not load
//! `tauri.localhost` (Chromium maps `*.localhost` to loopback and shows
//! “无法访问此页面”).

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;

pub static FRONTEND_PORT: OnceLock<u16> = OnceLock::new();

pub fn frontend_origin() -> String {
    format!(
        "http://127.0.0.1:{}",
        FRONTEND_PORT.get().copied().unwrap_or(0)
    )
}

pub fn frontend_url(query: &str) -> String {
    if query.is_empty() {
        format!("{}/index.html", frontend_origin())
    } else {
        format!("{}/index.html?{query}", frontend_origin())
    }
}

pub fn start() -> std::io::Result<u16> {
    let dist = find_dist().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotFound, "frontend dist not found")
    })?;
    let listener = bind()?;
    let port = listener.local_addr()?.port();
    let _ = FRONTEND_PORT.set(port);
    let log = std::env::temp_dir().join("lens-ui-server.log");
    let _ = std::fs::write(
        &log,
        format!("listening on 127.0.0.1:{port} dist={}\n", dist.display()),
    );
    // Leak the listener so the accept loop cannot drop it.
    let listener = Box::leak(Box::new(listener));
    thread::Builder::new()
        .name("lens-ui".into())
        .spawn(move || loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    let dist = dist.clone();
                    let _ = thread::spawn(move || {
                        let _ = serve_one(stream, &dist);
                    });
                }
                Err(err) => {
                    let _ = std::fs::OpenOptions::new()
                        .append(true)
                        .open(&log)
                        .and_then(|mut file| {
                            use std::io::Write as _;
                            writeln!(file, "accept error: {err}")
                        });
                    thread::sleep(Duration::from_millis(20));
                }
            }
        })?;
    wait_until_ready(port)?;
    Ok(port)
}

fn bind() -> std::io::Result<TcpListener> {
    for port in 18760..18820 {
        if let Ok(listener) = TcpListener::bind(("127.0.0.1", port)) {
            let _ = listener.set_nonblocking(false);
            return Ok(listener);
        }
    }
    TcpListener::bind("127.0.0.1:0")
}

fn wait_until_ready(port: u16) -> std::io::Result<()> {
    for _ in 0..50 {
        if let Ok(mut stream) = TcpStream::connect(("127.0.0.1", port)) {
            let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
            stream.write_all(
                b"GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
            )?;
            let mut buf = [0_u8; 24];
            let n = stream.read(&mut buf).unwrap_or(0);
            if n >= 12 && buf.starts_with(b"HTTP/1.1 200") {
                return Ok(());
            }
        }
        thread::sleep(Duration::from_millis(20));
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::ConnectionRefused,
        "ui server did not become ready",
    ))
}

fn find_dist() -> Option<PathBuf> {
    if let Ok(val) = std::env::var("LENS_DIST_PATH") {
        let env_path = PathBuf::from(val);
        if env_path.join("index.html").is_file() {
            if let Ok(canon) = env_path.canonicalize() {
                return Some(canon);
            }
        }
    }
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let candidates = [
        dir.join("dist"),
        dir.join("resources").join("dist"),
        dir.join("resources"),
        dir.join("../../../dist"),
        dir.join("../../dist"),
    ];
    candidates.into_iter().find_map(|path| {
        if path.join("index.html").is_file() {
            path.canonicalize().ok()
        } else {
            None
        }
    })
}

fn serve_one(mut stream: TcpStream, dist: &Path) -> std::io::Result<()> {
    let mut buf = [0_u8; 8192];
    let n = stream.read(&mut buf)?;
    let request = String::from_utf8_lossy(&buf[..n]);
    let target = request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or("/");
    let rel = target
        .split('?')
        .next()
        .unwrap_or("/")
        .trim_start_matches('/');
    let rel = if rel.is_empty() { "index.html" } else { rel };
    let file = dist.join(rel);
    let allowed = file
        .canonicalize()
        .ok()
        .filter(|canon| canon.starts_with(dist));
    if let Some(path) = allowed.filter(|path| path.is_file()) {
        let body = std::fs::read(&path)?;
        let mime = mime_of(&path);
        let header = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(header.as_bytes())?;
        stream.write_all(&body)?;
        return Ok(());
    }
    let body = b"not found";
    stream.write_all(
        format!(
            "HTTP/1.1 404 Not Found\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .as_bytes(),
    )?;
    stream.write_all(body)?;
    Ok(())
}

fn mime_of(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "json" => "application/json",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}
