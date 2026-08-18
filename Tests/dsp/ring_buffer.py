from collections import deque

class RingBuffer:
    def __init__(self, capacity: int):
        self.capacity = capacity
        self.buf = [None] * capacity
        self.wpos = 0
        self.rpos = 0
        self.size = 0
        self.overruns = 0
        self.underruns = 0

    def push(self, data):
        if not data:
            return 0
        n = len(data)
        if n > self.capacity:
            data = data[-self.capacity:]
            n = self.capacity
        dropped = 0
        if self.size + n > self.capacity:
            dropped = self.size + n - self.capacity
            self.rpos = (self.rpos + dropped) % self.capacity
            self.size = self.capacity - n
            self.overruns += dropped
        for i, v in enumerate(data):
            self.buf[(self.wpos + i) % self.capacity] = v
        self.wpos = (self.wpos + n) % self.capacity
        if dropped:
            self.size = self.capacity
        else:
            self.size += n
        return dropped

    def pop(self, count: int):
        out = []
        avail = min(self.size, count)
        for i in range(avail):
            out.append(self.buf[(self.rpos + i) % self.capacity])
        if avail < count:
            out.extend([0.0] * (count - avail))
            self.underruns += count - avail
        self.rpos = (self.rpos + avail) % self.capacity
        self.size -= avail
        return out

    def available(self): return self.size
    def free_space(self): return self.capacity - self.size
    def reset(self):
        self.wpos = 0; self.rpos = 0; self.size = 0
        self.overruns = 0; self.underruns = 0
