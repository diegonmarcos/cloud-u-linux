//! my-ai shared core: data-driven config + endpoints (migrated from claude-superset).
//! Session-hub client and health collectors land in Phase 2/3.
use serde::Deserialize;

/// Endpoints are compiled in from src/data/endpoints.json (data-driven, single source).
pub const ENDPOINTS_JSON: &str = include_str!("../../src/data/endpoints.json");

#[derive(Debug, Clone, Deserialize)]
pub struct Endpoints {
    pub proxy: String,
    pub api: String,
    pub ollama: String,
    pub anthropic: String,
    #[serde(default)]
    pub sync_keep: u32,
}

pub fn endpoints() -> anyhow::Result<Endpoints> {
    Ok(serde_json::from_str(ENDPOINTS_JSON)?)
}

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn endpoints_parse() {
        let e = endpoints().expect("endpoints.json must parse");
        assert!(e.api.starts_with("http"));
        assert_eq!(e.sync_keep, 20);
    }
}
