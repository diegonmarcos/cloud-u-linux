// pty-core: transport-agnostic PTY broker. No GUI/Tauri deps — output goes through a sink callback.
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Mutex;

pub mod fs;

pub enum PtyEvent {
    Output { id: String, data: String },
    Exit { id: String },
}

struct Pty {
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
}

#[derive(Default)]
pub struct PtyBroker {
    ptys: Mutex<HashMap<String, Pty>>,
}

impl PtyBroker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn start(
        &self,
        id: String,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        sink: impl Fn(PtyEvent) + Send + 'static,
    ) -> Result<(), String> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| e.to_string())?;

        let mut cmd = CommandBuilder::new(user_shell());
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        let dir = match cwd {
            Some(d) if !d.is_empty() => d,
            _ => std::env::var("HOME").unwrap_or_default(),
        };
        cmd.cwd(dir);

        pair.slave
            .spawn_command(cmd)
            .map_err(|e| e.to_string())?;

        let reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

        self.ptys.lock().unwrap().insert(
            id.clone(),
            Pty {
                writer,
                master: pair.master,
            },
        );

        std::thread::spawn(move || {
            let mut reader = reader;
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => {
                        sink(PtyEvent::Exit { id });
                        break;
                    }
                    Ok(n) => {
                        let data = String::from_utf8_lossy(&buf[..n]).into_owned();
                        sink(PtyEvent::Output {
                            id: id.clone(),
                            data,
                        });
                    }
                }
            }
        });

        Ok(())
    }

    pub fn write(&self, id: &str, data: &str) -> Result<(), String> {
        let mut ptys = self.ptys.lock().unwrap();
        if let Some(pty) = ptys.get_mut(id) {
            pty.writer
                .write_all(data.as_bytes())
                .map_err(|e| e.to_string())?;
            pty.writer.flush().map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let ptys = self.ptys.lock().unwrap();
        if let Some(pty) = ptys.get(id) {
            pty.master
                .resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    // drop the PTY (SIGHUP to shell); no-op if unknown
    pub fn kill(&self, id: &str) {
        self.ptys.lock().unwrap().remove(id);
    }
}

/// MYK_SHELL || SHELL || "/bin/bash"
pub fn user_shell() -> String {
    std::env::var("MYK_SHELL")
        .or_else(|_| std::env::var("SHELL"))
        .unwrap_or_else(|_| "/bin/bash".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use std::thread::sleep;
    use std::time::Duration;

    #[test]
    fn start_write_echo_kill() {
        let broker = PtyBroker::new();
        let output = Arc::new(Mutex::new(String::new()));
        let output_clone = output.clone();

        broker
            .start("t".to_string(), 80, 24, None, move |ev| {
                if let PtyEvent::Output { data, .. } = ev {
                    output_clone.lock().unwrap().push_str(&data);
                }
            })
            .unwrap();

        broker.write("t", "echo HELLO_PTY_CORE\r").unwrap();
        sleep(Duration::from_millis(300));

        let collected = output.lock().unwrap().clone();
        assert!(collected.contains("HELLO_PTY_CORE"), "got: {collected}");

        broker.kill("t");
    }
}
