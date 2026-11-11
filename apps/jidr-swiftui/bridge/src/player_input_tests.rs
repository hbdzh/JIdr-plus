#![cfg(test)]
use super::*;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use tokio::sync::{Notify, Semaphore};

#[derive(Clone, Debug, PartialEq)]
enum Event {
    Touch(i32, i32, i32, i32),
    Key(i32, i32, String, i32),
    Clipboard(String),
    Subscribe,
    Read,
    Closed,
}
type Trace = Arc<Mutex<Vec<Event>>>;

struct Wire {
    trace: Trace,
    input_calls: usize,
    block_at: Option<usize>,
    fail_at: Option<usize>,
    entered: Arc<Notify>,
    gate: Arc<Semaphore>,
    clipboard: VecDeque<String>,
}
impl Wire {
    fn new() -> Self {
        Self {
            trace: Arc::default(),
            input_calls: 0,
            block_at: None,
            fail_at: None,
            entered: Arc::default(),
            gate: Arc::new(Semaphore::new(0)),
            clipboard: VecDeque::from(["old snapshot".into(), "new copied text".into()]),
        }
    }
    async fn input(&mut self, event: Event) -> Result<()> {
        self.trace.lock().unwrap().push(event);
        self.input_calls += 1;
        if self.block_at == Some(self.input_calls) {
            self.entered.notify_one();
            let _permit = self.gate.acquire().await.unwrap();
        }
        if self.fail_at == Some(self.input_calls) {
            bail!("simulated lost reply");
        }
        Ok(())
    }
}
impl InputWire for Wire {
    async fn touch(&mut self, event: pb::TouchEvent) -> Result<()> {
        let t = &event.touches[0];
        self.input(Event::Touch(t.identifier, t.x, t.y, t.pressure))
            .await
    }
    async fn key(&mut self, event: pb::KeyboardEvent) -> Result<()> {
        self.input(Event::Key(
            event.code_type,
            event.key_code,
            event.key,
            event.event_type,
        ))
        .await
    }
    async fn set_clipboard(&mut self, text: String) -> Result<()> {
        self.trace.lock().unwrap().push(Event::Clipboard(text));
        Ok(())
    }
    async fn subscribe_clipboard(&mut self) -> Result<()> {
        self.trace.lock().unwrap().push(Event::Subscribe);
        Ok(())
    }
    async fn next_clipboard(&mut self) -> Result<Option<String>> {
        self.trace.lock().unwrap().push(Event::Read);
        Ok(self.clipboard.pop_front())
    }
    fn close_clipboard(&mut self) {
        self.trace.lock().unwrap().push(Event::Closed);
    }
}

struct Handler {
    state: InputState<Wire>,
    rotation: AtomicU32,
}
impl SerialInput for Handler {
    async fn handle(&mut self, line: String) {
        self.state
            .command(
                serde_json::from_str(&line).unwrap(),
                (720, 1280),
                &self.rotation,
            )
            .await
            .unwrap();
    }
    async fn release(&mut self) {
        self.state.release().await;
    }
}
fn handler(wire: Wire) -> Handler {
    Handler {
        state: InputState::new(wire),
        rotation: AtomicU32::new(0),
    }
}
fn key_event_trace(code: i32, down: bool) -> Event {
    Event::Key(
        pb::keyboard_event::KeyCodeType::Evdev as i32,
        code,
        String::new(),
        if down {
            pb::keyboard_event::KeyEventType::Keydown as i32
        } else {
            pb::keyboard_event::KeyEventType::Keyup as i32
        },
    )
}
fn inputs(trace: &Trace) -> Vec<Event> {
    trace
        .lock()
        .unwrap()
        .iter()
        .filter(|x| matches!(x, Event::Key(..) | Event::Touch(..)))
        .cloned()
        .collect()
}

#[tokio::test]
async fn fifo_drains_bounded_queue_without_reordering_repeats_or_chords() {
    let wire = Wire::new();
    let trace = Arc::clone(&wire.trace);
    let (tx, rx) = mpsc::channel(2);
    let (_stop, stopped) = oneshot::channel();
    let task = tokio::spawn(worker(handler(wire), rx, stopped));
    for _ in 0..100 {
        for down in [true, true, false] {
            tx.send(json!({"type":"key","key":"a","down":down}).to_string())
                .await
                .unwrap();
        }
    }
    tx.send(json!({"type":"paste","text":"中文\n日本語 🙂"}).to_string())
        .await
        .unwrap();
    tx.send(json!({"type":"select_all"}).to_string())
        .await
        .unwrap();
    drop(tx);
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .unwrap()
        .unwrap();
    let events = inputs(&trace);
    assert_eq!(events.len(), 308);
    for group in events[..300].as_chunks::<3>().0 {
        assert!(
            matches!(&group[0],Event::Key(_,_,key,t) if key=="a" && *t==pb::keyboard_event::KeyEventType::Keydown as i32)
        );
        assert_eq!(group[0], group[1]);
        assert!(
            matches!(&group[2],Event::Key(_,_,key,t) if key=="a" && *t==pb::keyboard_event::KeyEventType::Keyup as i32)
        );
    }
    let expected: Vec<_> = [47, 30]
        .into_iter()
        .flat_map(|code| {
            [
                key_event_trace(29, true),
                key_event_trace(code, true),
                key_event_trace(code, false),
                key_event_trace(29, false),
            ]
        })
        .collect();
    assert_eq!(events[300..], expected);
    assert!(
        trace
            .lock()
            .unwrap()
            .contains(&Event::Clipboard("中文\n日本語 🙂".into()))
    );
}

#[tokio::test]
async fn blocked_command_keeps_later_up_queued_and_other_work_progressing() {
    let mut wire = Wire::new();
    wire.block_at = Some(1);
    let trace = Arc::clone(&wire.trace);
    let entered = Arc::clone(&wire.entered);
    let gate = Arc::clone(&wire.gate);
    let (tx, rx) = mpsc::channel(1);
    let (_stop, stopped) = oneshot::channel();
    let task = tokio::spawn(worker(handler(wire), rx, stopped));
    tx.send(json!({"type":"key","key":"Shift","down":true}).to_string())
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(1), entered.notified())
        .await
        .unwrap();
    tx.send(json!({"type":"key","key":"Shift","down":false}).to_string())
        .await
        .unwrap();
    assert!(matches!(
        tx.try_send("another".into()),
        Err(mpsc::error::TrySendError::Full(_))
    ));
    // A current-thread runtime must continue polling frame/other work while
    // the input RPC is blocked. No per-event spawn may overtake the down.
    let frames = tokio::spawn(async {
        for _ in 0..30 {
            tokio::task::yield_now().await;
        }
        30
    });
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(1), frames)
            .await
            .unwrap()
            .unwrap(),
        30
    );
    assert_eq!(inputs(&trace).len(), 1);
    gate.add_permits(1);
    drop(tx);
    task.await.unwrap();
    assert_eq!(inputs(&trace).len(), 2);
}

#[tokio::test]
async fn disconnect_at_every_clipboard_chord_step_releases_possible_downs() {
    for block in 1..=4 {
        let mut wire = Wire::new();
        wire.block_at = Some(block);
        let trace = Arc::clone(&wire.trace);
        let entered = Arc::clone(&wire.entered);
        let (tx, rx) = mpsc::channel(2);
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(worker(handler(wire), rx, stopped));
        tx.send(json!({"type":"paste","text":"文字"}).to_string())
            .await
            .unwrap();
        tx.send(json!({"type":"key","key":"b","down":true}).to_string())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), entered.notified())
            .await
            .unwrap();
        stop.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .unwrap()
            .unwrap();
        let mut expected = vec![
            key_event_trace(29, true),
            key_event_trace(47, true),
            key_event_trace(47, false),
            key_event_trace(29, false),
        ];
        expected.truncate(block);
        if block == 2 || block == 3 {
            expected.push(key_event_trace(47, false));
        }
        expected.push(key_event_trace(29, false));
        assert_eq!(inputs(&trace), expected, "cancelled chord step {block}");
    }
}

#[tokio::test]
async fn eof_releases_long_press_and_multiple_fingers_in_reverse_press_order() {
    let wire = Wire::new();
    let trace = Arc::clone(&wire.trace);
    let (tx, rx) = mpsc::channel(8);
    let (_stop, stopped) = oneshot::channel();
    let task = tokio::spawn(worker(handler(wire), rx, stopped));
    for value in [
        json!({"type":"key","key":"Control","down":true}),
        json!({"type":"key","key":"a","down":true}),
        json!({"type":"touch","x":0.5,"y":0.5,"down":true}),
        json!({"type":"mapped_touch","id":3,"x":0.25,"y":0.25,"down":true}),
        json!({"type":"touch","x":0.75,"y":0.75,"down":true}),
    ] {
        tx.send(value.to_string()).await.unwrap();
    }
    drop(tx);
    task.await.unwrap();
    let events = inputs(&trace);
    assert_eq!(events.len(), 9);
    assert_eq!(events[5], Event::Touch(3, 180, 320, 0));
    assert_eq!(events[6], Event::Touch(1, 540, 960, 0));
    assert!(
        matches!(&events[7],Event::Key(_,_,key,t) if key=="a" && *t==pb::keyboard_event::KeyEventType::Keyup as i32)
    );
    assert!(
        matches!(&events[8],Event::Key(_,_,key,t) if key=="Control" && *t==pb::keyboard_event::KeyEventType::Keyup as i32)
    );
}

#[tokio::test]
async fn cancellation_during_chord_error_recovery_retries_remaining_releases() {
    let mut wire = Wire::new();
    wire.fail_at = Some(2); // V down may have reached Android.
    wire.block_at = Some(3); // Its recovery up has not been acknowledged.
    let trace = Arc::clone(&wire.trace);
    let entered = Arc::clone(&wire.entered);
    let (tx, rx) = mpsc::channel(1);
    let (stop, stopped) = oneshot::channel();
    let task = tokio::spawn(worker(handler(wire), rx, stopped));
    tx.send(json!({"type":"paste","text":"text"}).to_string())
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(1), entered.notified())
        .await
        .unwrap();
    stop.send(()).unwrap();
    task.await.unwrap();
    assert_eq!(
        inputs(&trace),
        [
            key_event_trace(29, true),
            key_event_trace(47, true),
            key_event_trace(47, false),
            key_event_trace(47, false),
            key_event_trace(29, false)
        ]
    );
}

#[tokio::test]
async fn mapped_up_after_rotation_uses_last_delivered_position() {
    let wire = Wire::new();
    let trace = Arc::clone(&wire.trace);
    let mut state = InputState::new(wire);
    let rotation = AtomicU32::new(1);
    state
        .command(
            Command::MappedTouch {
                id: 3,
                x: 0.2,
                y: 0.3,
                down: true,
            },
            (720, 1280),
            &rotation,
        )
        .await
        .unwrap();
    rotation.store(3, Ordering::Relaxed);
    state
        .command(
            Command::MappedTouch {
                id: 3,
                x: 0.8,
                y: 0.9,
                down: false,
            },
            (720, 1280),
            &rotation,
        )
        .await
        .unwrap();
    assert!(state.held.is_empty());
    let events = inputs(&trace);
    let Event::Touch(_, x, y, _) = events[0] else {
        panic!("touch expected")
    };
    assert_eq!(events[1], Event::Touch(3, x, y, 0));
}

#[tokio::test]
async fn failed_down_reply_is_released_and_chord_failure_keeps_user_modifier() {
    let mut wire = Wire::new();
    wire.fail_at = Some(1);
    let trace = Arc::clone(&wire.trace);
    let mut state = InputState::new(wire);
    let r = AtomicU32::new(0);
    assert!(
        state
            .command(
                Command::Key {
                    key: "a".into(),
                    down: true
                },
                (720, 1280),
                &r
            )
            .await
            .is_err()
    );
    state.release().await;
    assert_eq!(inputs(&trace).len(), 2);
    assert!(state.held.is_empty());
    state
        .command(
            Command::Key {
                key: "Shift".into(),
                down: true,
            },
            (720, 1280),
            &r,
        )
        .await
        .unwrap();
    state.wire.fail_at = Some(5); // Ctrl succeeds, V down loses its reply.
    assert!(
        state
            .command(
                Command::Paste {
                    text: "text".into()
                },
                (720, 1280),
                &r
            )
            .await
            .is_err()
    );
    assert_eq!(state.held.len(), 1);
    assert!(matches!(&state.held[0],Held::Key{key,..} if key=="Shift"));
    state.release().await;
    assert!(state.held.is_empty());
}

#[tokio::test]
async fn copy_and_cut_subscribe_before_chord_and_discard_stale_snapshot() {
    for cut in [false, true] {
        let wire = Wire::new();
        let trace = Arc::clone(&wire.trace);
        let mut state = InputState::new(wire);
        state
            .command(
                if cut {
                    Command::Cut { request_id: 7 }
                } else {
                    Command::Copy { request_id: 7 }
                },
                (720, 1280),
                &AtomicU32::new(0),
            )
            .await
            .unwrap();
        assert_eq!(
            *trace.lock().unwrap(),
            [
                Event::Subscribe,
                Event::Read,
                key_event_trace(29, true),
                key_event_trace(if cut { 45 } else { 46 }, true),
                key_event_trace(if cut { 45 } else { 46 }, false),
                key_event_trace(29, false),
                Event::Read,
                Event::Closed
            ]
        );
        assert!(state.held.is_empty());
    }
}

#[tokio::test]
async fn release_is_bounded_when_remote_never_answers() {
    let mut wire = Wire::new();
    wire.block_at = Some(2);
    let mut state = InputState::new(wire);
    state
        .command(
            Command::Key {
                key: "a".into(),
                down: true,
            },
            (720, 1280),
            &AtomicU32::new(0),
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(2), state.release())
        .await
        .unwrap();
    assert!(state.held.is_empty());
}

#[test]
fn scheduler_selector_retains_serial_fallback() {
    assert_eq!(Scheduling::parse("fifo"), Some(Scheduling::Fifo));
    assert_eq!(Scheduling::parse("inline"), Some(Scheduling::Inline));
    assert_eq!(Scheduling::parse("other"), None);
}

#[tokio::test]
async fn optional_rpc_trace_preserves_values_and_error_status() {
    for enabled in [false, true] {
        assert_eq!(
            traced_rpc(enabled, "test", std::future::ready(Ok(7)))
                .await
                .unwrap(),
            7
        );
        let error = traced_rpc::<()>(
            enabled,
            "test",
            std::future::ready(Err(tonic::Status::unavailable("offline"))),
        )
        .await
        .unwrap_err();
        assert_eq!(
            error.downcast_ref::<tonic::Status>().unwrap().code(),
            tonic::Code::Unavailable
        );
    }
}
