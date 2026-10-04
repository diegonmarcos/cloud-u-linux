// pty-core::fs — transport-agnostic filesystem ops shared by the Tauri app (src-tauri)
// and the ws engine. Same `~` -> $HOME expansion + dirs-first/case-insensitive sort
// that src-tauri's fs_list_dir used to do inline.
use serde::Serialize;

#[derive(Serialize)]
pub struct FsEntry {
    pub name: String,
    pub is_dir: bool,
}

fn expand_home(path: &str) -> Result<String, String> {
    if let Some(rest) = path.strip_prefix('~') {
        let home = std::env::var("HOME").map_err(|e| e.to_string())?;
        Ok(format!("{home}{rest}"))
    } else {
        Ok(path.to_string())
    }
}

pub fn list_dir(path: &str) -> Result<Vec<FsEntry>, String> {
    let expanded = expand_home(path)?;
    let mut entries: Vec<FsEntry> = std::fs::read_dir(&expanded)
        .map_err(|e| e.to_string())?
        .flatten()
        .filter_map(|e| {
            let is_dir = e.file_type().ok()?.is_dir();
            Some(FsEntry { name: e.file_name().to_string_lossy().into_owned(), is_dir })
        })
        .collect();
    entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    Ok(entries)
}

pub fn read_file(path: &str) -> Result<String, String> {
    let expanded = expand_home(path)?;
    std::fs::read_to_string(&expanded).map_err(|e| e.to_string())
}

pub fn write_file(path: &str, content: &str) -> Result<(), String> {
    let expanded = expand_home(path)?;
    // Create parent dirs so writing to a fresh path (e.g. logs/debug.log, or a
    // new file in the editor) doesn't fail on a missing directory.
    if let Some(parent) = std::path::Path::new(&expanded).parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&expanded, content).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_read_list_roundtrip() {
        let dir = std::env::temp_dir();
        let file = dir.join(format!("pty_core_fs_test_{}.txt", std::process::id()));
        let file_str = file.to_string_lossy().into_owned();

        write_file(&file_str, "HELLO_FS_CORE").unwrap();
        let content = read_file(&file_str).unwrap();
        assert_eq!(content, "HELLO_FS_CORE");

        let dir_str = dir.to_string_lossy().into_owned();
        let entries = list_dir(&dir_str).unwrap();
        let name = file.file_name().unwrap().to_string_lossy().into_owned();
        let found = entries.iter().find(|e| e.name == name);
        assert!(found.is_some(), "expected {name} in listing");
        assert!(!found.unwrap().is_dir);

        std::fs::remove_file(&file).ok();
    }
}
