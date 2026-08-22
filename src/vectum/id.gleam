import youid/uuid

/// Time-sortable unique ID (UUID v7).
pub fn event_id() -> String {
  uuid.v7_string()
}

pub fn delivery_id() -> String {
  uuid.v7_string()
}
