fn main() {
    // The direct XPC client is C: xpc_connection_set_event_handler takes a
    // block, which C has natively and Rust would need glue for.
    println!("cargo:rerun-if-changed=xpc/mihomo_control.c");
    println!("cargo:rerun-if-changed=xpc/mihomo_control.h");
    cc::Build::new()
        .file("xpc/mihomo_control.c")
        .flag("-fblocks")
        .warnings(true)
        .compile("mihomo_control");
    println!("cargo:rustc-link-lib=framework=Security");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");

    tauri_build::build()
}
