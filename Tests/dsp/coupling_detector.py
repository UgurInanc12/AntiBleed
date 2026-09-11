"""
Python mirror of AntiBleedApp/Core/CouplingDetector.swift. Keep in sync.

Ensemble acoustic-coupling detector:
  1. decimated (8x) cross-correlation of mic vs render over a 400 ms window,
     lag search centred on the AEC3 delay estimate when available,
  2. peak-lag stability across evaluations,
  3. AEC3 health (divergence) and evidence (ERLE).
"""
import numpy as np

SR = 48000


class CouplingDetector:
    def __init__(self, correlation_threshold=0.3, divergence_threshold=0.3, min_stable_windows=5,
                 max_delay_ms=250, hint_window_ms=15, analysis_window_ms=400, decimation=8,
                 lag_stable_tolerance_ms=4, erle_full_db=12.0, erle_start_db=3.0):
        self.correlation_threshold = correlation_threshold
        self.divergence_threshold = divergence_threshold
        self.min_stable_windows = min_stable_windows
        self.max_delay_ms = max_delay_ms
        self.hint_window_ms = hint_window_ms
        self.analysis_window_ms = analysis_window_ms
        self.decimation = decimation
        self.lag_stable_tolerance_ms = lag_stable_tolerance_ms
        self.erle_full_db = erle_full_db
        self.erle_start_db = erle_start_db
        self.reset()

    def reset(self):
        self.render_hist = np.zeros(0, dtype=np.float32)
        self.mic_hist = np.zeros(0, dtype=np.float32)
        self.stable_windows = 0
        self.last_peak_lag_ms = -1
        self.smoothed_score = 0.0
        self._rem_r = np.zeros(0, dtype=np.float32)
        self._rem_m = np.zeros(0, dtype=np.float32)

    @property
    def rate(self):
        return SR / self.decimation

    @property
    def history_capacity(self):
        return int(self.rate) * (self.analysis_window_ms + self.max_delay_ms) // 1000

    def push(self, render, mic):
        r = np.concatenate([self._rem_r, np.asarray(render, dtype=np.float32)])
        m = np.concatenate([self._rem_m, np.asarray(mic, dtype=np.float32)])
        n = (len(r) // self.decimation) * self.decimation
        if n:
            self.render_hist = np.concatenate([self.render_hist, r[:n].reshape(-1, self.decimation).mean(axis=1)])
            self.mic_hist = np.concatenate([self.mic_hist, m[:n].reshape(-1, self.decimation).mean(axis=1)])
        self._rem_r, self._rem_m = r[n:], m[n:]
        cap = self.history_capacity
        if len(self.render_hist) > cap:
            self.render_hist = self.render_hist[-cap:]
            self.mic_hist = self.mic_hist[-cap:]

    def _result(self, corr=0.0, delay_ms=-1):
        return {"score": float(np.clip(self.smoothed_score, 0, 1)), "correlation": float(corr),
                "stable_windows": self.stable_windows, "delay_ms": delay_ms}

    def evaluate(self, aec_stats):
        rate = self.rate
        win = int(rate) * self.analysis_window_ms // 1000
        max_lag = int(rate) * self.max_delay_ms // 1000
        if len(self.render_hist) < win + 1:
            return self._result()
        recent_r = self.render_hist[-win:]
        if np.sqrt(np.mean(recent_r ** 2)) < 1e-5:
            self.smoothed_score *= 0.8
            return self._result()

        mic_start = len(self.mic_hist) - win
        available = len(self.render_hist) - win
        lag_cap = min(max_lag, available)
        lag_lo, lag_hi, step = 0, lag_cap, max(1, int(rate) // 1000)
        d_ms = aec_stats.get("delayMs", -1)
        valid = aec_stats.get("valid", d_ms >= 0)
        if valid and d_ms >= 0:
            centre = int(d_ms / 1000 * rate)
            half = int(self.hint_window_ms / 1000 * rate)
            lag_lo, lag_hi, step = max(0, centre - half), min(lag_cap, centre + half), 1

        m = self.mic_hist[mic_start:mic_start + win].astype(np.float64)
        mic_e = float(np.dot(m, m))
        if mic_e < 1e-12:
            return self._result()
        best, best_lag = 0.0, 0
        for lag in range(lag_lo, lag_hi + 1, step):
            r_start = mic_start - lag
            r = self.render_hist[r_start:r_start + win].astype(np.float64)
            r_e = float(np.dot(r, r))
            if r_e > 1e-12:
                c = float(np.dot(r, m) / np.sqrt(r_e * mic_e))
                if abs(c) > abs(best):
                    best, best_lag = c, lag
        peak_lag_ms = int(best_lag / rate * 1000)

        if abs(best) > self.correlation_threshold:
            if self.last_peak_lag_ms >= 0 and abs(peak_lag_ms - self.last_peak_lag_ms) <= self.lag_stable_tolerance_ms:
                self.stable_windows += 1
            elif self.last_peak_lag_ms < 0:
                self.stable_windows = max(self.stable_windows, 1)
            self.last_peak_lag_ms = peak_lag_ms
        elif abs(best) < self.correlation_threshold * 0.7:
            self.stable_windows = max(0, self.stable_windows - 1)
            if self.stable_windows == 0:
                self.last_peak_lag_ms = -1

        div = aec_stats.get("divergentFilterFraction", 0.0)
        aec_health = 0.0 if div > self.divergence_threshold else (0.5 if div > 0.1 else 1.0)
        erle = aec_stats.get("erleDb", 0.0) if valid else 0.0
        erle_score = float(np.clip((erle - self.erle_start_db) / (self.erle_full_db - self.erle_start_db), 0, 1))
        corr_score = float(np.clip((abs(best) - 0.2) / 0.5, 0, 1))
        stability = float(np.clip(self.stable_windows / self.min_stable_windows, 0, 1))
        # D-022: ERLE confirms correlation, it cannot replace it. AEC3 freezes its
        # last ERLE when the echo path disappears (measured 37.2 dB held for 6+ s
        # after the echo was gone), which alone pinned the score at activeExit.
        erle_gate = float(np.clip((abs(best) - self.correlation_threshold * 0.5)
                                  / (self.correlation_threshold * 0.5), 0, 1))
        raw = (corr_score * 0.45 + erle_score * erle_gate * 0.35 + stability * 0.20) * (0.5 + 0.5 * aec_health)
        self.smoothed_score = 0.7 * self.smoothed_score + 0.3 * raw
        delay_ms = d_ms if (valid and d_ms >= 0) else peak_lag_ms
        out = self._result(best, delay_ms)
        out["peak_lag_ms"] = peak_lag_ms
        return out

    # Backwards-compatible one-shot API used by older tests.
    def update(self, render, mic, aec_stats, max_lag=None):
        self.push(render, mic)
        return self.evaluate(aec_stats)
