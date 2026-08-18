import numpy as np
from .signal_metrics import max_correlation

class CouplingDetector:
    def __init__(self, correlation_threshold=0.3, divergence_threshold=0.3, min_stable_windows=5):
        self.correlation_threshold = correlation_threshold
        self.divergence_threshold = divergence_threshold
        self.min_stable_windows = min_stable_windows
        self.stable_windows = 0
        self.last_peak_lag = 0
        self.smoothed_score = 0.0

    def reset(self):
        self.stable_windows = 0
        self.last_peak_lag = 0
        self.smoothed_score = 0.0

    def update(self, render: np.ndarray, mic: np.ndarray, aec_stats: dict, max_lag=240):
        if render is None or mic is None or len(render) == 0:
            return {"score": 0.0, "correlation": 0.0, "stable_windows": 0, "delay_ms": -1}
        corr, lag = max_correlation(render, mic, max_lag)
        # delay stability
        delay_stable = False
        d_ms = aec_stats.get("delayMs", -1)
        d_std = aec_stats.get("delayStddevMs", 99)
        if d_ms >= 0 and d_std < 5.0:
            delay_stable = abs(lag - self.last_peak_lag) < 20
        if abs(corr) > self.correlation_threshold and delay_stable:
            self.stable_windows += 1
        elif abs(corr) < self.correlation_threshold * 0.7:
            self.stable_windows = max(0, self.stable_windows - 1)

        self.last_peak_lag = lag

        div_frac = aec_stats.get("divergentFilterFraction", 0.0)
        if div_frac > self.divergence_threshold:
            aec_health = 0.0
        elif div_frac > 0.1:
            aec_health = 0.5
        else:
            aec_health = 1.0

        corr_score = float(np.clip((abs(corr) - 0.2) / 0.5, 0, 1))
        stability_score = float(np.clip(self.stable_windows / self.min_stable_windows, 0, 1))
        raw = corr_score * 0.5 + stability_score * 0.3 + aec_health * 0.2
        self.smoothed_score = 0.8 * self.smoothed_score + 0.2 * raw
        score = float(np.clip(self.smoothed_score, 0, 1))
        delay_ms = d_ms if d_ms >= 0 else int(lag * 1000 / 48000)
        return {
            "score": score,
            "correlation": float(corr),
            "stable_windows": self.stable_windows,
            "delay_ms": delay_ms,
            "delay_stddev_ms": float(d_std),
            "peak_lag": lag,
        }
