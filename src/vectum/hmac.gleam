import gleam/bit_array
import gleam/crypto
import gleam/string

/// GitHub-compatible HMAC-SHA256 signature: `sha256=<hex>`.
pub fn sign(secret: String, body: BitArray) -> String {
  let mac = crypto.hmac(body, crypto.Sha256, bit_array.from_string(secret))
  "sha256=" <> string.lowercase(bit_array.base16_encode(mac))
}

pub fn sign_string(secret: String, body: String) -> String {
  sign(secret, bit_array.from_string(body))
}

/// Accepts `sha256=<hex>` or a bare hex digest. Comparison is constant-time.
pub fn verify(secret: String, body: BitArray, provided: String) -> Bool {
  let expected = sign(secret, body)
  let normalised = normalise(provided)
  crypto.secure_compare(
    bit_array.from_string(expected),
    bit_array.from_string(normalised),
  )
}

pub fn verify_string(secret: String, body: String, provided: String) -> Bool {
  verify(secret, bit_array.from_string(body), provided)
}

fn normalise(signature: String) -> String {
  let trimmed = string.lowercase(string.trim(signature))
  case string.starts_with(trimmed, "sha256=") {
    True -> trimmed
    False -> "sha256=" <> trimmed
  }
}
