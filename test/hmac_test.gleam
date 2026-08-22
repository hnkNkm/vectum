import gleam/bit_array
import gleam/crypto
import gleam/string
import vectum/hmac

pub fn sign_and_verify_roundtrip_test() {
  let body = "Hello, World!"
  let secret = "It's a Secret to Everybody"
  let signature = hmac.sign_string(secret, body)
  assert string.starts_with(signature, "sha256=")
  assert hmac.verify_string(secret, body, signature)
  assert hmac.verify_string(
    secret,
    body,
    string.drop_start(from: signature, up_to: 7),
  )
}

pub fn verify_rejects_wrong_secret_or_body_test() {
  let signature = hmac.sign_string("secret", "hello")
  assert !hmac.verify_string("other", "hello", signature)
  assert !hmac.verify_string("secret", "hallo", signature)
}

pub fn known_sha256_vector_test() {
  let mac =
    crypto.hmac(bit_array.from_string("Hi There"), crypto.Sha256, <<
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
      0x0b,
    >>)
  assert string.lowercase(bit_array.base16_encode(mac))
    == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
}
