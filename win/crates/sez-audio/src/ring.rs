use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use thiserror::Error;

/// Error returned when constructing an SPSC ring buffer.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum RingBufferError {
    /// A ring needs at least one slot.
    #[error("ring buffer capacity must be greater than zero")]
    ZeroCapacity,
}

struct Inner {
    slots: Box<[AtomicU32]>,
    capacity: usize,
    head: AtomicUsize,
    tail: AtomicUsize,
    dropped: AtomicU64,
}

/// Fixed-capacity single-producer/single-consumer ring buffer for mono `f32` samples.
///
/// Construction allocates the backing storage. [`RingProducer::push`] and
/// [`RingConsumer::pop`] perform only atomic operations afterwards.
pub struct SpscRingBuffer {
    inner: Arc<Inner>,
}

impl SpscRingBuffer {
    /// Allocates a ring with exactly `capacity` usable sample slots.
    pub fn new(capacity: usize) -> Result<Self, RingBufferError> {
        if capacity == 0 {
            return Err(RingBufferError::ZeroCapacity);
        }

        let slots = std::iter::repeat_with(|| AtomicU32::new(0))
            .take(capacity)
            .collect::<Vec<_>>()
            .into_boxed_slice();
        Ok(Self {
            inner: Arc::new(Inner {
                slots,
                capacity,
                head: AtomicUsize::new(0),
                tail: AtomicUsize::new(0),
                dropped: AtomicU64::new(0),
            }),
        })
    }

    /// Consumes the ring and returns its unique producer and consumer handles.
    pub fn split(self) -> (RingProducer, RingConsumer) {
        (
            RingProducer {
                inner: Arc::clone(&self.inner),
            },
            RingConsumer { inner: self.inner },
        )
    }
}

/// Unique producer handle for [`SpscRingBuffer`].
pub struct RingProducer {
    inner: Arc<Inner>,
}

impl RingProducer {
    /// Pushes one sample.
    ///
    /// Returns `false` when the ring is full. In that case the incoming sample
    /// is dropped, existing samples remain untouched, and the dropped counter
    /// is incremented.
    #[inline]
    pub fn push(&mut self, sample: f32) -> bool {
        let head = self.inner.head.load(Ordering::Relaxed);
        let tail = self.inner.tail.load(Ordering::Acquire);
        if head.wrapping_sub(tail) >= self.inner.capacity {
            self.inner.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }

        self.inner.slots[head % self.inner.capacity].store(sample.to_bits(), Ordering::Relaxed);
        self.inner
            .head
            .store(head.wrapping_add(1), Ordering::Release);
        true
    }

    /// Returns the number of incoming samples dropped since construction.
    pub fn dropped_count(&self) -> u64 {
        self.inner.dropped.load(Ordering::Relaxed)
    }
}

/// Unique consumer handle for [`SpscRingBuffer`].
pub struct RingConsumer {
    inner: Arc<Inner>,
}

impl RingConsumer {
    /// Pops the oldest buffered sample, preserving FIFO order.
    #[inline]
    pub fn pop(&mut self) -> Option<f32> {
        let tail = self.inner.tail.load(Ordering::Relaxed);
        let head = self.inner.head.load(Ordering::Acquire);
        if tail == head {
            return None;
        }

        let bits = self.inner.slots[tail % self.inner.capacity].load(Ordering::Relaxed);
        self.inner
            .tail
            .store(tail.wrapping_add(1), Ordering::Release);
        Some(f32::from_bits(bits))
    }

    /// Returns the number of incoming samples dropped since construction.
    pub fn dropped_count(&self) -> u64 {
        self.inner.dropped.load(Ordering::Relaxed)
    }
}
