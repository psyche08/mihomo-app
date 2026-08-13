//! Main-thread bridge to the in-process SwiftUI window.
//!
//! The exported Swift functions are `@MainActor` and touch AppKit. Their raw
//! symbols must therefore never be called directly from a Tauri worker. These
//! safe wrappers always enqueue the call on Tauri's main event loop first.
//!
//! A successful return means that Tauri accepted the main-thread task; the C
//! ABI is intentionally one-way and does not report whether AppKit ultimately
//! showed or hid the window.

#[cfg(target_os = "macos")]
use std::ffi::c_int;
use tauri::AppHandle;

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn mihomobox_ui_show() -> c_int;
    fn mihomobox_ui_shutdown();
    fn pthread_main_np() -> c_int;
}

#[cfg(target_os = "macos")]
fn show_on_main_thread() {
    let visible = unsafe { mihomobox_ui_show() } != 0;
    crate::app_log::info(&format!(
        "event=native_window action=show visible={visible}"
    ));
}

#[cfg(target_os = "macos")]
fn run_show_on_main_thread(app: &AppHandle) -> tauri::Result<()> {
    // Tauri's setup callback already runs on AppKit's main thread, before the
    // event loop begins processing queued tasks. Calling `run_on_main_thread`
    // there would postpone the initial window indefinitely on some macOS
    // versions, so execute immediately when pthread confirms the main thread.
    if unsafe { pthread_main_np() } != 0 {
        show_on_main_thread();
        return Ok(());
    }
    app.run_on_main_thread(show_on_main_thread)
}

/// Shows and focuses the single native SwiftUI window, creating it on demand.
#[cfg(target_os = "macos")]
pub fn show(app: &AppHandle) -> tauri::Result<()> {
    run_show_on_main_thread(app)
}

/// Tears down the native window and exits after the main-thread work finishes.
#[cfg(target_os = "macos")]
pub fn shutdown_and_exit(app: &AppHandle, code: i32) -> tauri::Result<()> {
    let exit_app = app.clone();
    app.run_on_main_thread(move || {
        // Safety: see `run_on_main_thread`; shutdown runs before Tauri stops
        // the event loop, allowing stream cancellation to reach the daemon.
        unsafe { mihomobox_ui_shutdown() };
        exit_app.exit(code);
    })
}

// MihomoBox only ships on macOS, but no-op fallbacks keep `cargo check` useful
// if the crate is inspected from another host.
#[cfg(not(target_os = "macos"))]
pub fn show(_app: &AppHandle) -> tauri::Result<()> {
    Ok(())
}

#[cfg(not(target_os = "macos"))]
pub fn shutdown_and_exit(app: &AppHandle, code: i32) -> tauri::Result<()> {
    app.exit(code);
    Ok(())
}
