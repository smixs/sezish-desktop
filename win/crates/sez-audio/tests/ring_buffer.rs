use sez_audio::SpscRingBuffer;
use std::collections::VecDeque;

fn next_random(state: &mut u64) -> u64 {
    *state = state
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(1);
    *state
}

#[test]
fn randomized_interleaved_operations_preserve_fifo_and_total_count() {
    for capacity in 1..=64 {
        let ring = SpscRingBuffer::new(capacity).expect("positive capacity is valid");
        let (mut producer, mut consumer) = ring.split();
        let mut expected = VecDeque::new();
        let mut random = capacity as u64;
        let mut next_value = 0_u32;
        let mut accepted = 0_usize;
        let mut consumed = 0_usize;
        let mut dropped = 0_u64;

        for _ in 0..5_000 {
            if next_random(&mut random).is_multiple_of(3) {
                let actual = consumer.pop();
                let wanted = expected.pop_front();
                assert_eq!(actual, wanted);
                consumed += usize::from(actual.is_some());
            } else {
                let sample = next_value as f32;
                next_value += 1;
                let was_accepted = producer.push(sample);
                if expected.len() == capacity {
                    assert!(!was_accepted);
                    dropped += 1;
                } else {
                    assert!(was_accepted);
                    expected.push_back(sample);
                    accepted += 1;
                }
            }
        }

        while let Some(actual) = consumer.pop() {
            assert_eq!(Some(actual), expected.pop_front());
            consumed += 1;
        }

        assert!(expected.is_empty());
        assert_eq!(consumed, accepted);
        assert_eq!(producer.dropped_count(), dropped);
        assert_eq!(consumer.dropped_count(), dropped);
    }
}

#[test]
fn overflow_drops_incoming_sample_and_keeps_oldest_samples() {
    let ring = SpscRingBuffer::new(2).expect("positive capacity is valid");
    let (mut producer, mut consumer) = ring.split();

    assert!(producer.push(10.0));
    assert!(producer.push(20.0));
    assert!(!producer.push(30.0));

    assert_eq!(producer.dropped_count(), 1);
    assert_eq!(consumer.pop(), Some(10.0));
    assert_eq!(consumer.pop(), Some(20.0));
    assert_eq!(consumer.pop(), None);
}
