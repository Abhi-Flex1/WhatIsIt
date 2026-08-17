fn main() {
    // Treat HarmonyOS (target_env = "ohos") the same as musl for cfg purposes,
    // since libc already maps ohos to musl-compatible definitions.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("ohos")
    {
        println!("cargo:rustc-cfg=target_env=\"musl\"");
    }

    println!("cargo:rerun-if-changed=build.rs");
}
