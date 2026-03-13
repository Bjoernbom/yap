use std::process::Command;

fn main() {
    tauri_build::build();

    // Add rpath for Swift runtime libraries (needed by screencapturekit + knf-rs-sys)
    // Swift Concurrency is in the OS on macOS 13+, but the backcompat dylib may still
    // be referenced by compiled Swift artifacts.
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");

    if let Ok(output) = Command::new("xcode-select").arg("-p").output() {
        if output.status.success() {
            let xcode_path = String::from_utf8_lossy(&output.stdout).trim().to_string();

            // Swift 5.5 backcompat path (has libswift_Concurrency.dylib)
            let swift_55_path = format!(
                "{}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx",
                xcode_path
            );
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", swift_55_path);

            // Modern Swift runtime path
            let swift_path = format!(
                "{}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
                xcode_path
            );
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", swift_path);
        }
    }
}
