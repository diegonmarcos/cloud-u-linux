// integration smoke test: start the engine in-process, drive a real PTY over ws.
use std::net::TcpStream;
use std::time::{Duration, Instant};
use tungstenite::Message;

#[test]
fn smoke_start_write_output() {
    let addr = "127.0.0.1:7399";
    std::thread::spawn(move || my_konsole_engine::run(addr));
    std::thread::sleep(Duration::from_millis(200)); // let the listener bind

    // ponytail: connect our own TcpStream (not tungstenite::connect's MaybeTlsStream)
    // so we can set a read timeout before handing it to the ws handshake.
    let tcp = TcpStream::connect(addr).expect("tcp connect");
    tcp.set_read_timeout(Some(Duration::from_millis(200))).ok();
    let (mut ws, _resp) = tungstenite::client(format!("ws://{addr}"), tcp).expect("ws handshake");

    ws.send(Message::Text(
        r#"{"op":"start","id":"t","cols":80,"rows":24,"cwd":null}"#.into(),
    ))
    .unwrap();
    ws.send(Message::Text(
        r#"{"op":"write","id":"t","data":"echo HELLO_ENGINE\r"}"#.into(),
    ))
    .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    let mut found = false;
    while Instant::now() < deadline && !found {
        match ws.read() {
            Ok(Message::Text(txt)) => {
                if txt.contains("HELLO_ENGINE") && txt.contains("\"ev\":\"output\"") {
                    found = true;
                }
            }
            Ok(_) => {}
            Err(_) => {} // read timeout / would-block; keep polling until deadline
        }
    }

    ws.send(Message::Text(r#"{"op":"kill","id":"t"}"#.into()))
        .ok();
    assert!(found, "expected an output frame containing HELLO_ENGINE");
}

#[test]
fn smoke_fs_write_read() {
    let addr = "127.0.0.1:7398";
    std::thread::spawn(move || my_konsole_engine::run(addr));
    std::thread::sleep(Duration::from_millis(200)); // let the listener bind

    let tcp = TcpStream::connect(addr).expect("tcp connect");
    tcp.set_read_timeout(Some(Duration::from_millis(200))).ok();
    let (mut ws, _resp) = tungstenite::client(format!("ws://{addr}"), tcp).expect("ws handshake");

    let path = std::env::temp_dir().join(format!("myk_engine_fs_test_{}.txt", std::process::id()));
    let path_str = path.to_string_lossy().into_owned();

    let write_req = serde_json::json!({"op":"fs_write","rid":1,"path":path_str,"content":"HELLO_FS"});
    ws.send(Message::Text(write_req.to_string().into())).unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    let mut write_ok = false;
    while Instant::now() < deadline && !write_ok {
        match ws.read() {
            Ok(Message::Text(txt)) => {
                if txt.contains("\"ev\":\"fs_result\"") && txt.contains("\"rid\":1") && txt.contains("\"ok\":true")
                {
                    write_ok = true;
                }
            }
            Ok(_) => {}
            Err(_) => {}
        }
    }
    assert!(write_ok, "expected ok fs_result for fs_write");

    let read_req = serde_json::json!({"op":"fs_read","rid":2,"path":path_str});
    ws.send(Message::Text(read_req.to_string().into())).unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    let mut read_ok = false;
    while Instant::now() < deadline && !read_ok {
        match ws.read() {
            Ok(Message::Text(txt)) => {
                if txt.contains("\"ev\":\"fs_result\"") && txt.contains("\"rid\":2") && txt.contains("HELLO_FS") {
                    read_ok = true;
                }
            }
            Ok(_) => {}
            Err(_) => {}
        }
    }
    assert!(read_ok, "expected fs_result containing HELLO_FS for fs_read");

    std::fs::remove_file(&path).ok();
}
