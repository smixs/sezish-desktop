use sez_audio::{push_interleaved_f32, SpscRingBuffer};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct CountingAllocator;

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::SeqCst);
        // SAFETY: Delegating the allocation request unchanged to the system allocator.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::SeqCst);
        // SAFETY: Delegating the allocation request unchanged to the system allocator.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: `ptr` and `layout` came from the system allocator above.
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::SeqCst);
        // SAFETY: `ptr` and `layout` came from the system allocator above.
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: CountingAllocator = CountingAllocator;

#[test]
fn producer_downmix_and_push_path_allocates_nothing() {
    let ring = SpscRingBuffer::new(16).expect("positive capacity is valid");
    let (mut producer, mut consumer) = ring.split();
    let stereo = [0.25_f32, 0.75, -0.5, 0.5, 1.0, -1.0, 0.4, 0.2];

    let before = ALLOCATIONS.load(Ordering::SeqCst);
    for _ in 0..10_000 {
        let stats =
            push_interleaved_f32(&mut producer, &stereo, 2).expect("two-channel input is valid");
        assert_eq!(stats.frames, 4);
        assert_eq!(stats.dropped, 0);
        for _ in 0..4 {
            assert!(consumer.pop().is_some());
        }
    }
    let after = ALLOCATIONS.load(Ordering::SeqCst);

    assert_eq!(after, before);
}
