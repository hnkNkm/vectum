/// Process environment access used for HMAC secret resolution.
@external(erlang, "vectum_ffi", "get_env")
pub fn get(name: String) -> Result(String, Nil)

@external(erlang, "vectum_ffi", "set_env")
pub fn set(name: String, value: String) -> Nil

@external(erlang, "vectum_ffi", "unset_env")
pub fn unset(name: String) -> Nil
