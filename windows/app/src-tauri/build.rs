fn main() {
    // CI stamps the build number (the commit count, as on the Mac).
    println!("cargo:rerun-if-env-changed=MACMINT_BUILD");
    tauri_build::build()
}
