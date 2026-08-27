// my-konsole-engine: blocking WebSocket PTY server over pty-core. No tauri/webkitgtk deps.
use pty_core::{PtyBroker, PtyEvent};
use serde::{Deserialize, Serialize};
use std::io::ErrorKind;
use std::net::{TcpListener, TcpStream};
use std::sync::{mpsc, Arc};
use std::time::Duration;
use tungstenite::{accept, Message};

// client -> server, tagged by "op"
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
enum ClientOp {
    Start {
        id: String,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
    },
    Write {
        id: String,
        data: String,
    },
    Resize {
        id: String,
        cols: u16,
        rows: u16,
    },
    Kill {
        id: String,
    },
    Auth {
        token: String,
    },
    #[serde(rename = "fs_list")]
    FsList {
        rid: u64,
        path: String,
    },
    #[serde(rename = "fs_read")]
    FsRead {
        rid: u64,
        path: String,
    },
    #[serde(rename = "fs_write")]
    FsWrite {
        rid: u64,
        path: String,
        content: String,
    },
}

// server -> client, tagged by "ev"
#[derive(Serialize)]
#[serde(tag = "ev", rename_all = "lowercase")]
enum ServerEv {
    Output { id: String, data: String },
    Exit { id: String },
    #[serde(rename = "fs_result")]
    FsResult {
        rid: u64,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        entries: Option<Vec<pty_core::fs::FsEntry>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
}

impl ServerEv {
    fn fs_ok(rid: u64, entries: Option<Vec<pty_core::fs::FsEntry>>, content: Option<String>) -> Self {
        ServerEv::FsResult { rid, ok: true, entries, content, error: None }
    }
    fn fs_err(rid: u64, error: String) -> Self {
        ServerEv::FsResult { rid, ok: false, entries: None, content: None, error: Some(error) }
    }
}

/// Blocking accept loop; one thread per connection. Bind whatever addr is passed —
/// the loopback-only default lives in main(), not here.
pub fn run(addr: &str) {
    let listener = TcpListener::bind(addr).expect("bind");
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        std::thread::spawn(move || handle_conn(stream));
    }
}

fn handle_conn(stream: TcpStream) {
    let mut ws = match accept(stream) {
        Ok(w) => w,
        Err(_) => return,
    };
    // ponytail: tungstenite's WebSocket doesn't split cleanly into independent
    // read/write halves, so instead of Arc<Mutex<..>> + separate threads we run a
    // single-threaded select loop: short read timeout on the socket, try an inbound
    // read, then drain whatever pty output piled up on the mpsc channel this tick.
    if ws
        .get_mut()
        .set_read_timeout(Some(Duration::from_millis(200)))
        .is_err()
    {
        return;
    }

    let token = std::env::var("MYK_ENGINE_TOKEN").ok();
    let mut authed = token.is_none();

    let broker = Arc::new(PtyBroker::new()); // ponytail: one broker per connection = per frontend instance
    let (tx, rx) = mpsc::channel::<String>();

    loop {
        while let Ok(json) = rx.try_recv() {
            if ws.send(Message::Text(json.into())).is_err() {
                return;
            }
        }

        match ws.read() {
            Ok(Message::Text(txt)) => {
                let op: ClientOp = match serde_json::from_str(txt.as_ref()) {
                    Ok(o) => o,
                    Err(_) => continue,
                };
                if !authed {
                    match &op {
                        ClientOp::Auth { token: t } if token.as_deref() == Some(t.as_str()) => {
                            authed = true;
                        }
                        _ => return, // first frame must be a matching auth op, else close
                    }
                    continue;
                }
                match op {
                    ClientOp::Auth { .. } => {} // already authed, no-op
                    ClientOp::Start {
                        id,
                        cols,
                        rows,
                        cwd,
                    } => {
                        let tx2 = tx.clone();
                        let _ = broker.start(id, cols, rows, cwd, move |ev| {
                            let ev = match ev {
                                PtyEvent::Output { id, data } => ServerEv::Output { id, data },
                                PtyEvent::Exit { id } => ServerEv::Exit { id },
                            };
                            if let Ok(json) = serde_json::to_string(&ev) {
                                let _ = tx2.send(json);
                            }
                        });
                    }
                    ClientOp::Write { id, data } => {
                        let _ = broker.write(&id, &data);
                    }
                    ClientOp::Resize { id, cols, rows } => {
                        let _ = broker.resize(&id, cols, rows);
                    }
                    ClientOp::Kill { id } => broker.kill(&id),
                    ClientOp::FsList { rid, path } => {
                        let ev = match pty_core::fs::list_dir(&path) {
                            Ok(entries) => ServerEv::fs_ok(rid, Some(entries), None),
                            Err(e) => ServerEv::fs_err(rid, e),
                        };
                        if let Ok(json) = serde_json::to_string(&ev) {
                            let _ = tx.send(json);
                        }
                    }
                    ClientOp::FsRead { rid, path } => {
                        let ev = match pty_core::fs::read_file(&path) {
                            Ok(content) => ServerEv::fs_ok(rid, None, Some(content)),
                            Err(e) => ServerEv::fs_err(rid, e),
                        };
                        if let Ok(json) = serde_json::to_string(&ev) {
                            let _ = tx.send(json);
                        }
                    }
                    ClientOp::FsWrite { rid, path, content } => {
                        let ev = match pty_core::fs::write_file(&path, &content) {
                            Ok(()) => ServerEv::fs_ok(rid, None, None),
                            Err(e) => ServerEv::fs_err(rid, e),
                        };
                        if let Ok(json) = serde_json::to_string(&ev) {
                            let _ = tx.send(json);
                        }
                    }
                }
            }
            Ok(Message::Close(_)) => return,
            Ok(_) => {} // ignore binary/ping/pong frames
            Err(tungstenite::Error::Io(e))
                if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut =>
            {
                // no inbound frame this tick; loop back and drain outbound queue again
            }
            Err(_) => return,
        }
        // `broker` (Arc) drops when the last clone goes away on return, which kills its PTYs.
    }
}
