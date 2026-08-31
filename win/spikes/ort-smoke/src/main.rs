// Throwaway spike (#6). ort with load-dynamic, no download-binaries.
use ndarray::Array1;
use ort::session::Session;
use ort::value::Tensor;

const FIXTURE: &[u8] = include_bytes!("../fixtures/add.onnx");

fn main() -> ort::Result<()> {
    println!("== ort smoke ==");
    // Honors ORT_DYLIB_PATH; otherwise finds onnxruntime.dll beside the exe / on PATH.
    ort::init().commit()?;

    let mut session = Session::builder()?.commit_from_memory(FIXTURE)?;

    let a = Tensor::from_array(Array1::from(vec![1.0f32, 2.0]))?;
    let b = Tensor::from_array(Array1::from(vec![3.0f32, 4.0]))?;
    let outputs = session.run(ort::inputs![
        "a" => a,
        "b" => b,
    ])?;

    let (_shape, data) = outputs["c"].try_extract_tensor::<f32>()?;
    println!("output c = {data:?} (expected [4.0, 6.0])");

    let ok = data.len() == 2 && (data[0] - 4.0).abs() < 1e-5 && (data[1] - 6.0).abs() < 1e-5;
    println!("RESULT: {}", if ok { "PASS" } else { "FAIL" });
    if !ok {
        std::process::exit(1);
    }
    Ok(())
}
