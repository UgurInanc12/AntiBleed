#!/usr/bin/env python3
"""
Generate synthetic fixtures for offline AEC tests (PLAN 28).
Output: Tests/OfflineFixtures/*.wav + fixtures.json manifest.

mic(t) = wantedVoice(t) + noise(t) + conv(render(t), IR)

Run on Windows without a Mac:
  python Tests/OfflineFixtures/generate.py
"""
import json, pathlib, math
import numpy as np

SR = 48000
OUT = pathlib.Path(__file__).parent

def make_speech_like(duration=1.0, seed=0):
    rng = np.random.default_rng(seed)
    n = int(duration * SR)
    t = np.arange(n) / SR
    s = (0.3*np.sin(2*math.pi*200*t) + 0.2*np.sin(2*math.pi*400*t) + 0.15*np.sin(2*math.pi*800*t))
    env = 0.5 + 0.5*np.sin(2*math.pi*3*t)
    return (s * env).astype(np.float32)

def make_sine(freq, duration=1.0, amp=0.4):
    n = int(duration * SR)
    t = np.arange(n) / SR
    return (amp * np.sin(2*math.pi*freq*t)).astype(np.float32)

def make_ir(delay_samples, gain, taps=1):
    ir = np.zeros(delay_samples + 1, dtype=np.float32)
    ir[delay_samples] = gain
    if taps > 1:
        # Add simple reflections
        for k in range(1, taps):
            if delay_samples + k*10 < len(ir):
                ir[delay_samples + k*10] = gain * 0.3 / k
    return ir

def save_wav(path, data, sr=SR):
    try:
        import soundfile as sf
        sf.write(str(path), data, sr)
    except ImportError:
        # Fallback: raw float32
        data.astype(np.float32).tofile(str(path) + ".f32")
        print(f"soundfile not installed, wrote raw f32: {path}.f32")

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {"sample_rate": SR, "frame_size": 480, "cases": []}

    # Case A: fixed echo
    render = make_speech_like(2.0, seed=1)
    wanted = make_sine(300, 2.0, amp=0.3)
    ir = make_ir(5, 0.5)
    from scipy.signal import lfilter
    echo = np.convolve(render, ir, mode='full')[:len(render)]
    mic = wanted + np.random.randn(len(render)).astype(np.float32)*0.02 + echo
    manifest["cases"].append({"id": "A_fixed_echo", "delay_samples": 5, "gain": 0.5, "render_rms": float(np.sqrt(np.mean(render**2)))})

    # Case B: delay sweep points
    for d in [0, 48, 240, 480, 1200]:
        manifest["cases"].append({"id": f"B_delay_{d}", "delay_samples": d})

    # Case H: no coupling (render and wanted uncorrelated)
    manifest["cases"].append({"id": "H_no_coupling", "description": "render uncorrelated with mic"})

    manifest_path = OUT / "fixtures.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"Wrote {manifest_path}")

    # Save example wavs if soundfile available
    try:
        import soundfile
        # Save a small example
        save_wav(OUT / "example_render.wav", render[:SR])
        save_wav(OUT / "example_mic.wav", mic[:SR])
        save_wav(OUT / "example_ir.wav", ir)
        print("Example wavs saved")
    except ImportError:
        print("pip install soundfile to save WAVs")

if __name__ == "__main__":
    main()
