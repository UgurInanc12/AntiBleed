import numpy as np

class Resampler:
    def __init__(self, from_rate: float, to_rate: float):
        self.from_rate = from_rate
        self.to_rate = to_rate
        self.ratio = from_rate / to_rate
        self.phase = 0.0

    def reset(self):
        self.phase = 0.0

    def process(self, x: np.ndarray) -> np.ndarray:
        if x is None or len(x) == 0:
            return np.array([], dtype=np.float32)
        if abs(self.from_rate - self.to_rate) < 1e-6:
            return x.astype(np.float32)
        # Simple linear interpolation streaming
        n_out = int(len(x) / self.ratio)
        if n_out <= 0:
            return np.array([], dtype=np.float32)
        out = np.zeros(n_out, dtype=np.float64)
        for i in range(n_out):
            pos = i * self.ratio
            idx = int(pos)
            frac = pos - idx
            if idx + 1 < len(x):
                out[i] = (1 - frac) * x[idx] + frac * x[idx + 1]
            else:
                out[i] = x[idx] if idx < len(x) else 0
        return out.astype(np.float32)
