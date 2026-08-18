import numpy as np
import math

def crossfade(a: np.ndarray, b: np.ndarray, progress: float) -> np.ndarray:
    p = float(np.clip(progress, 0, 1))
    return (1 - p) * a + p * b

def crossfade_equal_power(a: np.ndarray, b: np.ndarray, progress: float) -> np.ndarray:
    p = float(np.clip(progress, 0, 1))
    g_a = math.cos(p * math.pi / 2)
    g_b = math.sin(p * math.pi / 2)
    return g_a * a + g_b * b

class CrossfadeState:
    def __init__(self):
        self.total_frames = 0
        self.current = 0
        self.active = False
    def start(self, num_frames: int):
        self.total_frames = num_frames
        self.current = 0
        self.active = num_frames > 0
    def progress(self) -> float:
        if not self.active or self.total_frames == 0:
            return 1.0
        return max(0.0, min(1.0, self.current / self.total_frames))
    def advance(self):
        if not self.active:
            return
        self.current += 1
        if self.current >= self.total_frames:
            self.active = False
    def reset(self):
        self.total_frames = 0; self.current = 0; self.active = False
