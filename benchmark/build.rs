use std::path::PathBuf;

fn main() {
    let wat_path = PathBuf::from("../wat/extended_vft.wat");
    println!("cargo:rerun-if-changed={}", wat_path.display());

    let wat_text = std::fs::read_to_string(&wat_path)
        .unwrap_or_else(|e| panic!("read {}: {e}", wat_path.display()));
    let wasm = wat::parse_str(&wat_text).expect("WAT compile");

    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR");
    let out_path = PathBuf::from(out_dir).join("extended_vft.wasm");
    std::fs::write(&out_path, &wasm).expect("write wasm");
}
