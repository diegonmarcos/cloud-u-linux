// entry point: read addr from env (loopback-only default), run the blocking ws server.
fn main() {
    let addr = std::env::var("MYK_ENGINE_ADDR").unwrap_or_else(|_| "127.0.0.1:7333".to_string());
    my_konsole_engine::run(&addr);
}
