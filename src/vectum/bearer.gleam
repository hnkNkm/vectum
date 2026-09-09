import gleam/bit_array
import gleam/crypto
import gleam/string

/// `Authorization: Bearer <token>` の検証。scheme は大小文字非依存
/// (RFC 7235) で解釈し、token 比較は定数時間。
pub fn verify(token: String, provided: String) -> Bool {
  case extract_token(provided) {
    Error(_) -> False
    Ok(presented) ->
      crypto.secure_compare(
        bit_array.from_string(token),
        bit_array.from_string(presented),
      )
  }
}

/// Authorization 値から `Bearer <token>` の token 部分を取り出す。
/// scheme と token の間の空白は 1 つに限る。token に空白が混ざる形式は
/// RFC 6750 の b64token に反するため拒否する。
fn extract_token(value: String) -> Result(String, Nil) {
  case string.split(string.trim(value), " ") {
    [scheme, presented] ->
      case string.lowercase(scheme) == "bearer", string.trim(presented) != "" {
        True, True -> Ok(string.trim(presented))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}
