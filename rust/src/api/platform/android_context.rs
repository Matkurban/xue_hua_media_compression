//! Android `ndk-context` initialization for Flutter FFI plugins.
//!
//! Flutter loads the Rust `.so` via the Dart VM, so `JNI_OnLoad` is not called.
//! The Java plugin passes `applicationContext` here before any Rust code needs JVM access.

use jni::{
    errors::ThrowRuntimeExAndDefault,
    objects::{JClass, JObject},
    refs::{Global, Reference},
    EnvUnowned,
};
use std::ffi::c_void;
use std::sync::OnceLock;

static CTX: OnceLock<Global<JObject<'static>>> = OnceLock::new();

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_flutter_1rust_1bridge_xue_1hua_1media_1compression_XueHuaMediaCompressionPlugin_initAndroid<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    ctx: JObject<'caller>,
) {
    unowned_env
        .with_env(|env| -> Result<(), jni::errors::Error> {
            let global_ref = env.new_global_ref(ctx.as_ref())?;
            let vm_ptr = env.get_java_vm()?.get_raw() as *mut c_void;
            let ctx_ptr = global_ref.as_raw() as *mut c_void;
            unsafe {
                ndk_context::initialize_android_context(vm_ptr, ctx_ptr);
            }
            let _ = CTX.set(global_ref);
            Ok(())
        })
        .resolve::<ThrowRuntimeExAndDefault>();
}
