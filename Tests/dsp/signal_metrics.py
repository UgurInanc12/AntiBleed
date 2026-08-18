import numpy as np
import math

def rms(data: np.ndarray) -> float:
    if data is None or len(data) == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(data.astype(np.float64)))))

def peak(data: np.ndarray) -> float:
    if data is None or len(data) == 0:
        return 0.0
    return float(np.max(np.abs(data)))

def rms_db(data: np.ndarray) -> float:
    r = rms(data)
    if r < 1e-9:
        return float('-inf')
    return 20 * math.log10(r)

def normalized_correlation(a: np.ndarray, b: np.ndarray, lag: int = 0) -> float:
    if a is None or b is None or len(a) == 0 or len(b) == 0:
        return 0.0
    n = len(a)
    if lag >= 0:
        if lag >= n:
            return 0.0
        aa = a[:n - lag]
        bb = b[lag:]
    else:
        lag = -lag
        if lag >= n:
            return 0.0
        aa = a[lag:]
        bb = b[:n - lag]
    if len(aa) == 0:
        return 0.0
    denom = math.sqrt(float(np.sum(aa*aa) * np.sum(bb*bb)))
    if denom < 1e-12:
        return 0.0
    return float(np.sum(aa * bb) / denom)

def max_correlation(render: np.ndarray, mic: np.ndarray, max_lag: int = 240):
    best_corr = 0.0
    best_lag = 0
    for lag in range(-max_lag, max_lag + 1):
        c = normalized_correlation(render, mic, lag)
        if abs(c) > abs(best_corr):
            best_corr = c
            best_lag = lag
    return best_corr, best_lag

def echo_attenuation_db(mic_component: np.ndarray, out_component: np.ndarray) -> float:
    if mic_component is None or out_component is None or len(mic_component) == 0:
        return 0.0
    r_mic = rms(mic_component)
    r_out = rms(out_component)
    if r_mic < 1e-9:
        return 0.0
    if r_out < 1e-9:
        return 60.0
    return 20 * math.log10(r_mic / r_out)
