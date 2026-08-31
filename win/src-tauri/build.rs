fn main() {
    println!("cargo:rerun-if-env-changed=SEZISH_CLOUD_ENDPOINT");
    println!("cargo:rerun-if-env-changed=SEZISH_CLOUD_KEY");

    let endpoint = build_value("SEZISH_CLOUD_ENDPOINT");
    let key = build_value("SEZISH_CLOUD_KEY");
    println!("cargo:rustc-env=SEZISH_BAKED_CLOUD_ENDPOINT={endpoint}");
    println!("cargo:rustc-env=SEZISH_BAKED_CLOUD_KEY={key}");

    tauri_build::build()
}

fn build_value(name: &str) -> String {
    let value = std::env::var(name).unwrap_or_default();
    assert!(
        !value.contains(['\r', '\n']),
        "{name} must not contain line breaks"
    );
    value
}
