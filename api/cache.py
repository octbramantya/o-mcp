"""Answers kept for TTL, and identical requests in flight run once (design/frontend.md §6): ten
viewers of one dashboard refreshing every 30 s make one query per widget, not ten. A faster
refresh than TTL gets the cached answer, which is what enforces the 30 s minimum. Errors are not
kept."""
import asyncio
import time

TTL = 30.0
MAX_ENTRIES = 2000


class Cache:
    def __init__(self, ttl=TTL):
        self.ttl, self.done, self.running = ttl, {}, {}

    async def get(self, key, compute):
        hit = self.done.get(key)
        if hit and hit[0] > time.monotonic():
            return hit[1]
        task = self.running.get(key)
        if task is None:
            task = asyncio.ensure_future(compute())
            self.running[key] = task
            task.add_done_callback(lambda t: self._finish(key, t))
        return await asyncio.shield(task)

    def _finish(self, key, task):
        self.running.pop(key, None)
        if task.cancelled() or task.exception() is not None:
            return
        now = time.monotonic()
        if len(self.done) >= MAX_ENTRIES:
            self.done = {k: v for k, v in self.done.items() if v[0] > now}
            if len(self.done) >= MAX_ENTRIES:
                self.done.clear()
        self.done[key] = (now + self.ttl, task.result())
