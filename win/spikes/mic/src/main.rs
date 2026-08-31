// Throwaway: does the VM expose a working capture device?
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

fn main() {
    let host = cpal::default_host();
    println!("== mic probe ==");
    match host.input_devices() {
        Ok(devs) => {
            for d in devs {
                println!("input device: {}", d.name().unwrap_or_default());
            }
        }
        Err(e) => println!("input_devices err: {e}"),
    }
    let Some(dev) = host.default_input_device() else {
        println!("RESULT: NO default input device");
        std::process::exit(1);
    };
    println!("default input: {}", dev.name().unwrap_or_default());
    let cfg = dev.default_input_config().expect("default_input_config");
    println!("config: {cfg:?}");

    let count = Arc::new(AtomicU64::new(0));
    let peak = Arc::new(AtomicU32::new(0));
    let c2 = count.clone();
    let p2 = peak.clone();
    let stream = dev
        .build_input_stream(
            &cfg.config(),
            move |data: &[f32], _: &_| {
                c2.fetch_add(data.len() as u64, Ordering::Relaxed);
                let mut mx = 0f32;
                for &s in data {
                    mx = mx.max(s.abs());
                }
                p2.fetch_max((mx * 1e6) as u32, Ordering::Relaxed);
            },
            |e| eprintln!("stream err: {e}"),
            None,
        )
        .expect("build_input_stream");
    stream.play().expect("play");
    std::thread::sleep(std::time::Duration::from_secs(2));
    drop(stream);
    let n = count.load(Ordering::Relaxed);
    let pk = peak.load(Ordering::Relaxed) as f32 / 1e6;
    println!("captured {n} samples in 2s, peak amplitude {pk:.4}");
    println!(
        "RESULT: {}",
        if n > 0 { "CAPTURE OK" } else { "NO SAMPLES" }
    );
}
