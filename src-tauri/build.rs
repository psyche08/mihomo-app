use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

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

    link_native_swiftui();

    tauri_build::build()
}

fn link_native_swiftui() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("Cargo manifest dir"));
    let project = manifest.parent().expect("project root");
    let swift_sources = project.join("Sources/MihomoBoxUI");
    let control_sources = project.join("Sources/MihomoControl");
    let swift_library_dir = project.join(".build/release");
    let swift_library = swift_library_dir.join("libMihomoBoxUI.a");
    println!(
        "cargo:rerun-if-changed={}",
        project.join("Package.swift").display()
    );
    println!("cargo:rerun-if-changed={}", swift_sources.display());
    println!("cargo:rerun-if-changed={}", control_sources.display());
    println!("cargo:rerun-if-changed={}", swift_library.display());
    if !swift_library.is_file() {
        panic!(
            "missing {}; run `npm run prepare:binaries` before Cargo",
            swift_library.display()
        );
    }
    println!(
        "cargo:rustc-link-search=native={}",
        swift_library_dir.display()
    );
    println!("cargo:rustc-link-lib=static=MihomoBoxUI");

    // Swift object files carry LC_LINKER_OPTION entries for their frameworks
    // and runtime libraries. ld consumes those automatically once it can find
    // the toolchain's macOS runtime directory.
    if let Some(runtime) = swift_runtime_path() {
        println!("cargo:rustc-link-search=native={}", runtime.display());
    }
    println!("cargo:rustc-link-search=native=/usr/lib/swift");
    let clang_runtime = clang_runtime_path().unwrap_or_else(|| {
        panic!("Xcode clang runtime is unavailable; install the full Xcode toolchain")
    });
    println!("cargo:rustc-link-search=native={}", clang_runtime.display());
    println!("cargo:rustc-link-lib=static=clang_rt.osx");
}

fn swift_runtime_path() -> Option<PathBuf> {
    let output = Command::new("/usr/bin/xcrun")
        .args(["--find", "swiftc"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let compiler = String::from_utf8(output.stdout).ok()?;
    let compiler = Path::new(compiler.trim());
    Some(compiler.parent()?.parent()?.join("lib/swift/macosx"))
}

fn clang_runtime_path() -> Option<PathBuf> {
    let output = Command::new("/usr/bin/xcrun")
        .args(["clang", "--print-resource-dir"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let resource = String::from_utf8(output.stdout).ok()?;
    let directory = PathBuf::from(resource.trim()).join("lib/darwin");
    directory
        .join("libclang_rt.osx.a")
        .is_file()
        .then_some(directory)
}
