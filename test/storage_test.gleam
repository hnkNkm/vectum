import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import simplifile
import sqlight
import vectum/event
import vectum/storage

fn sample_event(id: String) -> event.Event {
  event.Event(
    id:,
    source: "github",
    event_type: "push",
    timestamp: "2026-01-01T00:00:00.000Z",
    data: event.Object(dict.from_list([#("ref", event.String("main"))])),
    metadata: dict.from_list([#("x-github-event", "push")]),
  )
}

fn with_db(run: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = storage.connect(":memory:")
  let assert Ok(Nil) = storage.migrate(conn)
  run(conn)
}

pub fn accept_persists_event_and_deduped_deliveries_test() {
  use conn <- with_db
  let ev = sample_event("evt-1")
  let assert Ok(deliveries) =
    storage.accept(conn, ev, ["ci", "audit", "ci"], 1000, ["d1", "d2", "d3"])
  assert list.map(deliveries, fn(d) { d.destination }) == ["ci", "audit"]
  let assert Ok(loaded) = storage.get_event(conn, "evt-1")
  assert loaded.id == "evt-1"
  assert loaded.event_type == "push"
  let assert Ok(event.String("main")) = event.get_path(loaded.data, "ref")
  let assert Ok(2) = storage.count_pending(conn)
}

pub fn claim_due_marks_delivering_and_skips_future_test() {
  use conn <- with_db
  let ev = sample_event("evt-2")
  let assert Ok(_) =
    storage.accept(conn, ev, ["ci", "audit"], 1000, ["d1", "d2"])
  let assert Ok([first]) = storage.claim_due(conn, 1000, 1)
  assert first.status == storage.Delivering
  let assert Ok([second]) = storage.claim_due(conn, 1000, 10)
  assert first.id != second.id
  let assert Ok([]) = storage.claim_due(conn, 1000, 10)
}

pub fn retry_then_dead_letter_and_cli_ops_test() {
  use conn <- with_db
  let ev = sample_event("evt-3")
  let assert Ok([delivery]) = storage.accept(conn, ev, ["ci"], 1000, ["dead-1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  assert claimed.id == delivery.id
  let assert Ok(1) =
    storage.mark_retry(
      conn,
      claimed.id,
      1,
      5000,
      "timeout",
      1100,
      claimed.updated_at,
    )
  let assert Ok([]) = storage.claim_due(conn, 2000, 10)
  let assert Ok([again]) = storage.claim_due(conn, 5000, 10)
  let assert Ok(1) =
    storage.mark_dead(conn, again.id, 8, "boom", 6000, again.updated_at)
  let assert Ok([dead]) = storage.list_dead(conn)
  assert dead.status == storage.DeadLetter
  assert dead.last_error == Some("boom")
  let assert Ok(0) = storage.count_pending(conn)

  let assert Ok(1) = storage.retry_dead(conn, dead.id, 7000)
  let assert Ok([]) = storage.list_dead(conn)
  let assert Ok([pending]) = storage.claim_due(conn, 7000, 1)
  assert pending.status == storage.Delivering
  assert pending.attempts == 0

  let assert Ok(1) =
    storage.mark_dead(conn, pending.id, 8, "boom", 8000, pending.updated_at)
  let assert Ok(1) = storage.delete_dead(conn, pending.id)
  let assert Ok([]) = storage.list_dead(conn)
}

pub fn recover_resets_delivering_test() {
  use conn <- with_db
  let ev = sample_event("evt-4")
  let assert Ok(_) = storage.accept(conn, ev, ["ci"], 1000, ["r1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  assert claimed.status == storage.Delivering
  let assert Ok(_) = storage.recover(conn, 2000)
  let assert Ok([again]) = storage.claim_due(conn, 2000, 1)
  assert again.id == claimed.id
}

pub fn success_clears_pending_test() {
  use conn <- with_db
  let ev = sample_event("evt-5")
  let assert Ok(_) = storage.accept(conn, ev, ["ci"], 1000, ["s1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  let assert Ok(1) =
    storage.mark_success(conn, claimed.id, 1, 1500, claimed.updated_at)
  let assert Ok(0) = storage.count_pending(conn)
  let assert Ok([]) = storage.list_dead(conn)
}

pub fn reap_stale_delivering_moves_only_old_rows_test() {
  use conn <- with_db
  let ev = sample_event("evt-reap")
  let assert Ok([d1, _d2]) =
    storage.accept(conn, ev, ["ci", "audit"], 1000, ["rp-1", "rp-2"])
  // d1 を claim(accept と同 ms のため token=1001 で delivering に)
  let assert Ok([c1]) = storage.claim_due(conn, 1000, 1)
  assert c1.id == d1.id
  // d2 を token=2000 で delivering に
  let assert Ok([_c2]) = storage.claim_due(conn, 2000, 10)

  // cutoff=1500: 古い方(d1, token=1001)だけを pending に戻す
  let assert Ok(1) = storage.reap_stale_delivering(conn, 1500, 3000)
  let assert Ok([requeued]) = storage.claim_due(conn, 3000, 10)
  assert requeued.id == d1.id

  // 新しい時刻の delivering は残る
  let assert Ok(0) = storage.reap_stale_delivering(conn, 2000, 4000)
}

/// actor 再起動相当では recover が走らず、delivering が保持されること。
pub fn actor_start_does_not_recover_test() {
  let path = "tmp/vectum-recover-test.db"
  let _ = simplifile.create_directory("tmp")
  remove_db(path)

  let assert Ok(conn) = storage.connect(path)
  let assert Ok(_) = storage.migrate(conn)
  let ev = sample_event("evt-norecover")
  let assert Ok([_d]) = storage.accept(conn, ev, ["ci"], 1000, ["nr-1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)

  // actor を起動しても recover は走らない → claim できる pending は無い
  let assert Ok(started) = storage.start_supervised(path)
  let store = started.data
  let assert Ok([]) = storage.call_claim_due(store, 5000, 10)

  // 明示的な起動時復旧なら同じ Delivery が pending に戻り、再開できる
  let assert Ok(1) = storage.open_and_recover(path, 6000)
  let assert Ok([recovered]) = storage.call_claim_due(store, 6000, 10)
  assert recovered.id == claimed.id

  let assert Ok(_) = sqlight.close(conn)
  // actor はテスト VM 終了まで残る。ファイルは gitignore 済みの tmp/ に置く。
  remove_db(path)
}

fn remove_db(path: String) -> Nil {
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  let _ = simplifile.delete(path <> "-journal")
  Nil
}

/// mark_* は delivering の行にしか効かない。succeeded 行を
/// mark_retry で上書きできないこと(reaper 競合の防御)。
pub fn mark_retry_does_not_touch_succeeded_row_test() {
  use conn <- with_db
  let ev = sample_event("evt-guard")
  let assert Ok([d]) = storage.accept(conn, ev, ["ci"], 1000, ["g-1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  let _ = d
  let assert Ok(1) =
    storage.mark_success(conn, claimed.id, 1, 1100, claimed.updated_at)

  // succeeded 行への mark_retry / mark_dead は 0 件で無視される
  let assert Ok(0) =
    storage.mark_retry(
      conn,
      claimed.id,
      2,
      5000,
      "late",
      1200,
      claimed.updated_at,
    )
  let assert Ok(0) =
    storage.mark_dead(conn, claimed.id, 2, "late", 1300, claimed.updated_at)

  // retry_scheduled / dead_letter になっていない(claim も dead 一覧も空)
  let assert Ok([]) = storage.claim_due(conn, 999_999, 10)
  let assert Ok([]) = storage.list_dead(conn)
}

/// 存在しない / dead_letter 以外の ID への dead 操作は 0 行変更を返す。
pub fn dead_ops_on_missing_id_return_zero_test() {
  use conn <- with_db
  let ev = sample_event("evt-dead-missing")
  let assert Ok([d]) = storage.accept(conn, ev, ["ci"], 1000, ["dm-1"])
  let _ = d

  // 未存在 ID
  let assert Ok(0) = storage.retry_dead(conn, "nope", 2000)
  let assert Ok(0) = storage.delete_dead(conn, "nope")

  // dead_letter 以外の行(pending)も対象外
  let assert Ok(0) = storage.retry_dead(conn, "dm-1", 2000)
  let assert Ok(0) = storage.delete_dead(conn, "dm-1")
}

/// #47: delivery_ids 不足は "missing-id" を挿入せず Error にする。
/// event 行も rollback される。
pub fn short_delivery_ids_is_error_without_missing_id_test() {
  use conn <- with_db
  let ev = sample_event("evt-short-ids")
  let assert Error(_) =
    storage.accept(conn, ev, ["ci", "audit"], 1000, ["only-one"])
  let assert Error(_) = storage.get_event(conn, "evt-short-ids")
  let assert Ok(0) = storage.count_pending(conn)
}

/// #47: 失敗した accept のあとも同じ接続で受理できる(rollback で再利用可能)。
pub fn failed_accept_leaves_connection_reusable_test() {
  use conn <- with_db
  let ev = sample_event("evt-dup")
  let assert Ok(_) = storage.accept(conn, ev, ["ci"], 1000, ["dup-1"])
  let assert Error(_) = storage.accept(conn, ev, ["ci"], 1001, ["dup-2"])
  let ev2 = sample_event("evt-after-dup")
  let assert Ok([d]) = storage.accept(conn, ev2, ["ci"], 1002, ["after-1"])
  assert d.id == "after-1"
}

fn insert_raw_event(
  conn: sqlight.Connection,
  id: String,
  payload: String,
  metadata: String,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into events
       (id, source, event_type, timestamp, received_at, payload, metadata)
       values (?, 'github', 'push', '2026-01-01T00:00:00.000Z', 1000, ?, ?)",
      on: conn,
      with: [
        sqlight.text(id),
        sqlight.text(payload),
        sqlight.text(metadata),
      ],
      expecting: decode.success(Nil),
    )
  Nil
}

/// #50: 壊れた payload は Null に化けず Error になる。
pub fn corrupt_payload_is_error_test() {
  use conn <- with_db
  insert_raw_event(conn, "evt-bad-payload", "{not json", "{}")
  let assert Error(_) = storage.get_event(conn, "evt-bad-payload")
}

/// #50: 壊れた metadata は空 dict に化けず Error になる。
pub fn corrupt_metadata_is_error_test() {
  use conn <- with_db
  insert_raw_event(conn, "evt-bad-meta", "{\"a\": 1}", "{not json")
  let assert Error(_) = storage.get_event(conn, "evt-bad-meta")
}

/// #49: ファイル DB は migrate 後に WAL モードである。
pub fn file_db_uses_wal_mode_test() {
  let path = "tmp/vectum-wal-test.db"
  let _ = simplifile.create_directory("tmp")
  remove_db(path)
  let assert Ok(conn) = storage.connect(path)
  let assert Ok(_) = storage.migrate(conn)
  let assert Ok(rows) =
    sqlight.query("pragma journal_mode", on: conn, with: [], expecting: {
      use mode <- decode.field(0, decode.string)
      decode.success(mode)
    })
  assert rows == ["wal"]
  let assert Ok(_) = sqlight.close(conn)
  remove_db(path)
}

/// #68a: crash-recovery の耐久性。close した tmp ファイルを
/// open_and_recover で開き直し、get/claim が通ること。
/// (既存 tmp test は開きっぱなしの接続の再利用のみで close→再 open しない)
pub fn crash_recovery_reopens_closed_tmp_file_test() {
  let path = "tmp/vectum-durability-test.db"
  let _ = simplifile.create_directory("tmp")
  remove_db(path)

  let assert Ok(conn) = storage.connect(path)
  let assert Ok(_) = storage.migrate(conn)
  let ev = sample_event("evt-durable")
  let assert Ok([_, _]) =
    storage.accept(conn, ev, ["ci", "audit"], 1000, ["dur-1", "dur-2"])
  // 1 件を delivering のまま crash 相当で閉じる
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  let assert Ok(_) = sqlight.close(conn)

  // 開き直して復旧: delivering は pending に戻り、2 件とも再開できる
  let assert Ok(2) = storage.open_and_recover(path, 2000)

  let assert Ok(reopened) = storage.connect(path)
  let assert Ok(event) = storage.get_event(reopened, "evt-durable")
  assert event.id == "evt-durable"
  let assert Ok(due) = storage.claim_due(reopened, 2000, 10)
  assert list.length(due) == 2
  assert list.contains(list.map(due, fn(d) { d.id }), claimed.id)

  let assert Ok(_) = sqlight.close(reopened)
  remove_db(path)
}

/// F2: mark_* の claim 世代フェンス。
/// A claim(token t0) → reap → B claim(token t1 > t0) の後、
/// A の遅延 mark は 0 件で拒否され、行は B の mark だけが確定する。
/// (フェンスなしでは A の mark が B の結果を上書きしてしまう)
pub fn stale_claim_mark_cannot_overwrite_new_claim_test() {
  use conn <- with_db
  let ev = sample_event("evt-f2-fence")
  let assert Ok(_) = storage.accept(conn, ev, ["ci"], 1000, ["f2-1"])

  // 世代 1: A が claim し、claim token(updated_at)を得る
  let assert Ok([claim_a]) = storage.claim_due(conn, 1100, 1)
  let token_a = claim_a.updated_at

  // A が滞留 → reaper が pending に戻す(updated_at は reap 時刻へ進む)
  let assert Ok(1) = storage.reap_stale_delivering(conn, 1150, 1200)

  // 世代 2: B が同じ行を claim。token は世代 1 より確実に大きい
  let assert Ok([claim_b]) = storage.claim_due(conn, 1300, 1)
  assert claim_b.id == claim_a.id
  let token_b = claim_b.updated_at
  assert token_b > token_a

  // A の遅延 mark_retry は古い token のため 0 件(B の行は無傷)
  let assert Ok(0) =
    storage.mark_retry(
      conn,
      claim_a.id,
      1,
      999_999,
      "stale worker",
      1400,
      token_a,
    )

  // B の mark_success は新しい token で 1 件確定する
  let assert Ok(1) = storage.mark_success(conn, claim_b.id, 1, 1500, token_b)

  // 最終状態: succeeded。再 claim も dead 一覧も空
  let assert Ok(0) = storage.count_pending(conn)
  let assert Ok([]) = storage.claim_due(conn, 999_999, 10)
  let assert Ok([]) = storage.list_dead(conn)
}

/// F2: claim の token(updated_at)は直前の値より必ず大きくなる。
/// reap と claim が同じミリ秒に重なっても世代 token が衝突しない
/// (`max(?, updated_at + 1)` による繰り上げ)。
pub fn claim_token_strictly_increases_on_same_ms_requeue_test() {
  use conn <- with_db
  let ev = sample_event("evt-f2-bump")
  let assert Ok(_) = storage.accept(conn, ev, ["ci"], 900, ["f2-2"])

  // 世代 1: A が claim(token = 1000)
  let assert Ok([claim_a]) = storage.claim_due(conn, 1000, 1)
  assert claim_a.updated_at == 1000

  // A 滞留 → reaper が 11000ms に requeue(updated_at = 11000)
  let assert Ok(1) = storage.reap_stale_delivering(conn, 10_500, 11_000)

  // 世代 2: 同じ 11000ms に B が claim しても token は 11001 へ繰り上がる
  let assert Ok([claim_b]) = storage.claim_due(conn, 11_000, 1)
  assert claim_b.updated_at == 11_001
  assert claim_b.updated_at > claim_a.updated_at
}

/// --- #31: read-only ops CLI 用クエリ ---
fn accept_at(
  conn: sqlight.Connection,
  id: String,
  source: String,
  event_type: String,
  destination: String,
  now_ms: Int,
) -> Nil {
  let ev =
    event.Event(
      id:,
      source:,
      event_type:,
      timestamp: "2026-01-01T00:00:00.000Z",
      data: event.Object(dict.from_list([#("ref", event.String("main"))])),
      metadata: dict.new(),
    )
  let assert Ok([_]) =
    storage.accept(conn, ev, [destination], now_ms, [id <> "-d"])
  Nil
}

pub fn list_events_orders_and_filters_test() {
  use conn <- with_db
  accept_at(conn, "e-early", "github", "push", "ci", 1000)
  accept_at(conn, "e-mid", "github", "pull_request", "audit", 2000)
  accept_at(conn, "e-late", "gitlab", "push", "ci", 3000)

  // 受信の新しい順
  let assert Ok(all) = storage.list_events(conn, None, None, 10)
  assert list.map(all, fn(e) { e.id }) == ["e-late", "e-mid", "e-early"]

  // source / type フィルタ
  let assert Ok(github) = storage.list_events(conn, Some("github"), None, 10)
  assert list.map(github, fn(e) { e.id }) == ["e-mid", "e-early"]
  let assert Ok(pushes) = storage.list_events(conn, None, Some("push"), 10)
  assert list.map(pushes, fn(e) { e.id }) == ["e-late", "e-early"]
  let assert Ok(both) =
    storage.list_events(conn, Some("github"), Some("push"), 10)
  assert list.map(both, fn(e) { e.id }) == ["e-early"]

  // limit で先頭 N 件だけ返る
  let assert Ok(limited) = storage.list_events(conn, None, None, 2)
  assert list.map(limited, fn(e) { e.id }) == ["e-late", "e-mid"]
}

pub fn list_deliveries_filters_status_destination_and_limit_test() {
  use conn <- with_db
  accept_at(conn, "d-e1", "github", "push", "ci", 1000)
  accept_at(conn, "d-e2", "github", "push", "audit", 2000)
  accept_at(conn, "d-e3", "github", "push", "ci", 3000)

  // e1 の Delivery を成功させ、updated_at を 1500 にする
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 10)
  let assert Ok(1) =
    storage.mark_success(conn, claimed.id, 1, 1500, claimed.updated_at)
  assert claimed.id == "d-e1-d"

  let assert Ok(all) = storage.list_deliveries(conn, None, None, 10)
  assert list.map(all, fn(d) { d.id }) == ["d-e3-d", "d-e2-d", "d-e1-d"]

  let assert Ok(pending) =
    storage.list_deliveries(conn, Some(storage.Pending), None, 10)
  assert list.map(pending, fn(d) { d.id }) == ["d-e3-d", "d-e2-d"]

  let assert Ok(succeeded) =
    storage.list_deliveries(conn, Some(storage.Succeeded), None, 10)
  assert list.map(succeeded, fn(d) { d.id }) == ["d-e1-d"]

  let assert Ok(ci) = storage.list_deliveries(conn, None, Some("ci"), 10)
  assert list.map(ci, fn(d) { d.id }) == ["d-e3-d", "d-e1-d"]

  let assert Ok(both) =
    storage.list_deliveries(conn, Some(storage.Pending), Some("ci"), 10)
  assert list.map(both, fn(d) { d.id }) == ["d-e3-d"]

  let assert Ok(limited) = storage.list_deliveries(conn, None, None, 1)
  assert list.map(limited, fn(d) { d.id }) == ["d-e3-d"]
}

pub fn get_delivery_found_and_missing_test() {
  use conn <- with_db
  accept_at(conn, "g-e1", "github", "push", "ci", 1000)
  let assert Ok(delivery) = storage.get_delivery(conn, "g-e1-d")
  assert delivery.event_id == "g-e1"
  assert delivery.destination == "ci"
  assert delivery.status == storage.Pending
  assert delivery.attempts == 0
  assert delivery.next_attempt_at == 1000
  let assert Error(_) = storage.get_delivery(conn, "no-such-id")
}

pub fn list_event_deliveries_scoped_to_event_test() {
  use conn <- with_db
  let ev = sample_event("fan-e1")
  let assert Ok([d1, d2]) =
    storage.accept(conn, ev, ["ci", "audit"], 1000, ["fan-d1", "fan-d2"])
  let _ = d2
  accept_at(conn, "fan-e2", "github", "push", "other", 2000)

  // 1 件を成功させ updated_at を新しくする(どちらが claim されるかは問わない)
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  let assert Ok(1) =
    storage.mark_success(conn, claimed.id, 1, 1500, claimed.updated_at)
  assert list.contains([d1.id, d2.id], claimed.id)

  let assert Ok(for_e1) = storage.list_event_deliveries(conn, "fan-e1")
  let assert [first, second] = for_e1
  assert first.id == claimed.id
  assert first.status == storage.Succeeded
  assert list.contains([d1.id, d2.id], second.id)
  assert second.status == storage.Pending

  // 他 Event の Delivery は混ざらない
  let assert Ok(for_other) = storage.list_event_deliveries(conn, "fan-e2")
  assert list.map(for_other, fn(d) { d.destination }) == ["other"]
}

pub fn counts_by_status_and_oldest_open_test() {
  use conn <- with_db
  accept_at(conn, "s-e1", "github", "push", "ci", 1000)
  accept_at(conn, "s-e2", "github", "push", "ci", 2000)
  accept_at(conn, "s-e3", "github", "push", "ci", 3000)
  accept_at(conn, "s-e4", "github", "push", "ci", 4000)

  // e1 → succeeded / e2 → retry_scheduled / e3 → delivering / e4 → pending
  let assert Ok([c1]) = storage.claim_due(conn, 1000, 1)
  let assert Ok(1) = storage.mark_success(conn, c1.id, 1, 1500, c1.updated_at)
  let assert Ok([c2]) = storage.claim_due(conn, 2000, 1)
  let assert Ok(1) =
    storage.mark_retry(conn, c2.id, 1, 5000, "timeout", 2100, c2.updated_at)
  let assert Ok([_c3]) = storage.claim_due(conn, 3000, 1)

  let assert Ok(counts) = storage.counts_by_status(conn)
  assert list.length(counts) == 4
  assert list.contains(counts, #(storage.Succeeded, 1))
  assert list.contains(counts, #(storage.RetryScheduled, 1))
  assert list.contains(counts, #(storage.Delivering, 1))
  assert list.contains(counts, #(storage.Pending, 1))

  // pending / retry_scheduled 中最古は e2(updated_at=2100)
  let assert Ok(Some(2100)) = storage.oldest_open(conn)
  let assert Ok(snapshot) = storage.status_snapshot(conn)
  assert snapshot.oldest_open_since_ms == Some(2100)
  assert list.length(snapshot.counts) == 4

  // 空 DB では counts は空、oldest は None
  use empty <- with_db
  let assert Ok([]) = storage.counts_by_status(empty)
  let assert Ok(None) = storage.oldest_open(empty)
}

/// read-only クエリがどの行も変更しないこと(参照の実行が副作用を持たない)。
pub fn read_queries_do_not_mutate_state_test() {
  use conn <- with_db
  accept_at(conn, "r-e1", "github", "push", "ci", 1000)
  accept_at(conn, "r-e2", "github", "push", "audit", 2000)
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  let assert Ok(1) =
    storage.mark_retry(
      conn,
      claimed.id,
      2,
      5000,
      "boom",
      2500,
      claimed.updated_at,
    )

  // 一通り読む
  let assert Ok(_) = storage.status_snapshot(conn)
  let assert Ok(_) = storage.list_events(conn, None, None, 10)
  let assert Ok(_) = storage.list_event_deliveries(conn, "r-e1")
  let assert Ok(_) = storage.list_deliveries(conn, None, None, 10)
  let assert Ok(_) = storage.get_delivery(conn, "r-e1-d")
  let assert Ok(_) = storage.get_delivery(conn, claimed.id)
  let assert Ok(_) = storage.oldest_open(conn)

  // どの行も状態・試行回数・時刻が元のまま
  let assert Ok(retry) = storage.get_delivery(conn, "r-e1-d")
  assert retry.id == claimed.id
  assert retry.status == storage.RetryScheduled
  assert retry.attempts == 2
  assert retry.updated_at == 2500
  assert retry.next_attempt_at == 5000
  let assert Ok(pending) = storage.get_delivery(conn, "r-e2-d")
  assert pending.status == storage.Pending
  assert pending.attempts == 0
  assert pending.updated_at == 2000
  assert pending.next_attempt_at == 2000
  let assert Ok(2) = storage.count_pending(conn)

  // 期日通りの claim も変わらず機能する(読取りが claim を消費していない)
  let assert Ok(due) = storage.claim_due(conn, 5000, 2)
  assert list.contains(list.map(due, fn(d) { d.id }), claimed.id)
}

// --- #30: retention prune ---

const day_ms = 86_400_000

/// 任意の受信時刻で Event を直接挿入する(テストの時刻制御用)。
fn insert_event_at(
  conn: sqlight.Connection,
  id: String,
  received_at: Int,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into events
       (id, source, event_type, timestamp, received_at, payload, metadata)
       values (?, 'github', 'push', '2026-01-01T00:00:00.000Z', ?, '{}', '{}')",
      on: conn,
      with: [sqlight.text(id), sqlight.int(received_at)],
      expecting: decode.success(Nil),
    )
  Nil
}

/// 任意の status / updated_at で Delivery を直接挿入する。
fn insert_delivery_at(
  conn: sqlight.Connection,
  id: String,
  event_id: String,
  destination: String,
  status: String,
  updated_at: Int,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into deliveries
       (id, event_id, destination, status, attempts, next_attempt_at,
        last_attempt_at, last_error, created_at, updated_at)
       values (?, ?, ?, ?, 0, 0, null, null, ?, ?)",
      on: conn,
      with: [
        sqlight.text(id),
        sqlight.text(event_id),
        sqlight.text(destination),
        sqlight.text(status),
        sqlight.int(updated_at),
        sqlight.int(updated_at),
      ],
      expecting: decode.success(Nil),
    )
  Nil
}

/// 日数基準の共通 seed。now = 100 日前の epoch とし、prune は
/// succeeded 10 日 / dead_letter 30 日 / events 20 日より古い行を対象にする
/// (cutoff: 90 / 70 / 80 日前 epoch)。削除されない行:
/// 新しい terminal、cutoff ちょうど、未完了、参照付き Event、新しい孤児。
/// 期待される削除件数 #(succeeded, dead_letter, events) を返す。
fn seed_prune_db(conn: sqlight.Connection) -> #(Int, Int, Int) {
  let now = 100 * day_ms
  let ago = fn(days_old: Int) { now - days_old * day_ms }
  // 古い succeeded(削除対象)
  insert_event_at(conn, "e-succ-old", ago(15))
  insert_delivery_at(
    conn,
    "d-succ-old",
    "e-succ-old",
    "ci",
    "succeeded",
    ago(40),
  )
  // 新しい succeeded(残る)
  insert_event_at(conn, "e-succ-new", ago(5))
  insert_delivery_at(
    conn,
    "d-succ-new",
    "e-succ-new",
    "ci",
    "succeeded",
    ago(5),
  )
  // cutoff ちょうどは `<` のため残る
  insert_event_at(conn, "e-succ-edge", ago(10))
  insert_delivery_at(
    conn,
    "d-succ-edge",
    "e-succ-edge",
    "ci",
    "succeeded",
    ago(10),
  )
  // 古い dead_letter(削除対象)
  insert_event_at(conn, "e-dead-old", ago(50))
  insert_delivery_at(
    conn,
    "d-dead-old",
    "e-dead-old",
    "ci",
    "dead_letter",
    ago(40),
  )
  // 新しい dead_letter(残る)
  insert_event_at(conn, "e-dead-new", ago(25))
  insert_delivery_at(
    conn,
    "d-dead-new",
    "e-dead-new",
    "ci",
    "dead_letter",
    ago(25),
  )
  // 未完了は古くても絶対に残る
  insert_event_at(conn, "e-rsv-old", ago(70))
  insert_delivery_at(
    conn,
    "d-rsv-old",
    "e-rsv-old",
    "ci",
    "retry_scheduled",
    ago(70),
  )
  insert_event_at(conn, "e-open-old", ago(70))
  insert_delivery_at(conn, "d-open-old", "e-open-old", "ci", "pending", ago(70))
  // 孤児 Event: 古いのは削除、新しいのは残る
  insert_event_at(conn, "e-orphan-old", ago(70))
  insert_event_at(conn, "e-orphan-fresh", ago(5))
  // succeeded 削除で孤児化する古い Event(同一 tx 内で削除される)
  insert_event_at(conn, "e-free-old", ago(60))
  insert_delivery_at(
    conn,
    "d-free-old",
    "e-free-old",
    "ci",
    "succeeded",
    ago(60),
  )
  #(2, 1, 3)
}

pub fn retention_disabled_keeps_everything_test() {
  use conn <- with_db
  seed_prune_db(conn)
  let assert Ok(counts) =
    storage.prune(conn, 100 * day_ms, storage.Retention(0, 0, 0))
  assert counts == storage.PruneCounts(succeeded: 0, dead_letter: 0, events: 0)
  assert storage.retention_enabled(storage.Retention(0, 0, 0)) == False
  assert storage.retention_enabled(storage.Retention(1, 0, 0)) == True
  assert storage.retention_enabled(storage.Retention(0, 0, 30)) == True
  // 何も消えていない
  let assert Ok(succ) =
    storage.list_deliveries(conn, Some(storage.Succeeded), None, 100)
  assert list.length(succ) == 4
}

pub fn prune_deletes_only_expired_terminal_rows_test() {
  use conn <- with_db
  let #(expected_succ, expected_dead, expected_events) = seed_prune_db(conn)
  let assert Ok(counts) =
    storage.prune(
      conn,
      100 * day_ms,
      storage.Retention(
        succeeded_days: 10,
        dead_letter_days: 30,
        events_days: 20,
      ),
    )
  assert counts
    == storage.PruneCounts(
      succeeded: expected_succ,
      dead_letter: expected_dead,
      events: expected_events,
    )

  // 残る Delivery: 新しい terminal と未完了だけ
  let assert Ok(succ) =
    storage.list_deliveries(conn, Some(storage.Succeeded), None, 100)
  let succ_ids = list.map(succ, fn(d) { d.id })
  assert list.length(succ_ids) == 2
  assert list.contains(succ_ids, "d-succ-new")
  assert list.contains(succ_ids, "d-succ-edge")
  let assert Ok(dead) =
    storage.list_deliveries(conn, Some(storage.DeadLetter), None, 100)
  assert list.map(dead, fn(d) { d.id }) == ["d-dead-new"]
  let assert Ok(pending) =
    storage.list_deliveries(conn, Some(storage.Pending), None, 100)
  assert list.map(pending, fn(d) { d.id }) == ["d-open-old"]
  let assert Ok(rsv) =
    storage.list_deliveries(conn, Some(storage.RetryScheduled), None, 100)
  assert list.map(rsv, fn(d) { d.id }) == ["d-rsv-old"]

  // 残る Event: 未完了 Delivery が残る古いもの、新しいもの、孤児でないもの
  let assert Ok(events) = storage.list_events(conn, None, None, 100)
  let event_ids = list.map(events, fn(e) { e.id })
  assert list.length(event_ids) == 7
  list.each(
    [
      "e-dead-new", "e-open-old", "e-orphan-fresh", "e-rsv-old", "e-succ-edge",
      "e-succ-new", "e-succ-old",
    ],
    fn(id) {
      assert list.contains(event_ids, id)
    },
  )
}

/// Event を参照する Delivery が 1 件でも残っていれば、Event は古くても
/// 削除されない(succeeded の行だけ消える)。
pub fn prune_keeps_events_with_remaining_deliveries_test() {
  use conn <- with_db
  let now = 100 * day_ms
  let ago = fn(days: Int) { now - days * day_ms }
  insert_event_at(conn, "e-mixed", ago(100))
  insert_delivery_at(
    conn,
    "d-mixed-succ",
    "e-mixed",
    "ci",
    "succeeded",
    ago(100),
  )
  insert_delivery_at(
    conn,
    "d-mixed-open",
    "e-mixed",
    "audit",
    "pending",
    ago(100),
  )
  let assert Ok(counts) =
    storage.prune(
      conn,
      now,
      storage.Retention(
        succeeded_days: 10,
        dead_letter_days: 30,
        events_days: 1,
      ),
    )
  // succeeded の行は消えるが、pending が残るため Event は残る
  assert counts == storage.PruneCounts(succeeded: 1, dead_letter: 0, events: 0)
  let assert Ok(event) = storage.get_event(conn, "e-mixed")
  assert event.id == "e-mixed"
  let assert Ok(open) =
    storage.list_deliveries(conn, Some(storage.Pending), None, 100)
  assert list.map(open, fn(d) { d.id }) == ["d-mixed-open"]
}

pub fn prune_dry_run_reports_counts_without_mutating_test() {
  use conn <- with_db
  seed_prune_db(conn)
  let retention =
    storage.Retention(succeeded_days: 10, dead_letter_days: 30, events_days: 20)
  let assert Ok(rows) =
    sqlight.query(
      "select count(*) from deliveries",
      on: conn,
      with: [],
      expecting: {
        use n <- decode.field(0, decode.int)
        decode.success(n)
      },
    )
  let assert Ok(events_rows) =
    sqlight.query(
      "select count(*) from events",
      on: conn,
      with: [],
      expecting: {
        use n <- decode.field(0, decode.int)
        decode.success(n)
      },
    )
  let before_deliveries = case rows {
    [n] -> n
    _ -> 0
  }
  let before_events = case events_rows {
    [n] -> n
    _ -> 0
  }

  // dry-run は実 prune と同じ件数を報告する
  let assert Ok(first) = storage.prune_dry_run(conn, 100 * day_ms, retention)
  assert first == storage.PruneCounts(succeeded: 2, dead_letter: 1, events: 3)
  // 何も消えていないため 2 回目も同じ件数
  let assert Ok(second) = storage.prune_dry_run(conn, 100 * day_ms, retention)
  assert second == first

  // 行数が完全に不変
  let assert Ok(rows_after) =
    sqlight.query(
      "select count(*) from deliveries",
      on: conn,
      with: [],
      expecting: {
        use n <- decode.field(0, decode.int)
        decode.success(n)
      },
    )
  let assert Ok(events_after) =
    sqlight.query(
      "select count(*) from events",
      on: conn,
      with: [],
      expecting: {
        use n <- decode.field(0, decode.int)
        decode.success(n)
      },
    )
  assert rows_after == [before_deliveries]
  assert events_after == [before_events]

  // dry-run の後に実 prune すると同じ件数だけ消える
  let assert Ok(pruned) = storage.prune(conn, 100 * day_ms, retention)
  assert pruned == first
}

/// prune 中に 1 文でも失敗したら全体がロールバックされ、状態が変わらない。
pub fn failed_prune_rolls_back_entire_transaction_test() {
  use conn <- with_db
  // 特定 Delivery の削除を abort で失敗させる trigger
  let assert Ok(Nil) =
    sqlight.exec(
      "create trigger fail_poison before delete on deliveries
       when old.id = 'd-poison'
       begin
         select raise(abort, 'poison');
       end",
      conn,
    )
  let now = 100 * day_ms
  let ago = fn(days: Int) { now - days * day_ms }
  insert_event_at(conn, "e-clean", ago(50))
  insert_delivery_at(conn, "d-clean", "e-clean", "ci", "succeeded", ago(60))
  insert_event_at(conn, "e-poison", ago(40))
  insert_delivery_at(conn, "d-poison", "e-poison", "ci", "dead_letter", ago(50))

  let assert Error(_) =
    storage.prune(
      conn,
      now,
      storage.Retention(
        succeeded_days: 10,
        dead_letter_days: 30,
        events_days: 20,
      ),
    )
  // succeeded の先頭削除は成功していたはずだが、tx 全体が巻き戻る
  let assert Ok(d_clean) = storage.get_delivery(conn, "d-clean")
  assert d_clean.status == storage.Succeeded
  let assert Ok(d_poison) = storage.get_delivery(conn, "d-poison")
  assert d_poison.status == storage.DeadLetter
  let assert Ok(_) = storage.get_event(conn, "e-clean")
  let assert Ok(_) = storage.get_event(conn, "e-poison")
}
