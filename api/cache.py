"""Answers kept until their data moves, and identical requests in flight run once (design/frontend.md
§6). An answer read from telemetry is kept with the version of the sources it read (api/fresh.py)
and stays valid until a source moves on, at most MAX_AGE; one that reads only the graph is kept for
TTL. A faster refresh than either gets the cached answer, which is what enforces the 30 s minimum.
Errors are not kept."""
import asyncio
import time

TTL = 30.0
MAX_AGE = 900.0      # an answer whose sources haven't moved, recomputed anyway: the graph may have changed
MAX_ENTRIES = 2000


class Cache:
    def __init__(self, ttl=TTL, max_age=MAX_AGE):
        self.ttl, self.max_age, self.done, self.running = ttl, max_age, {}, {}

    async def get(self, key, compute, version=None):
        """version None: the answer reads no telemetry and is kept for TTL. Otherwise it is kept while
        the caller's version is the one it was computed at. A request at a newer version doesn't
        share a computation started at an older one, whose data may be older than it expects."""
        hit = self.done.get(key)
        if hit and hit[0] > time.monotonic() and hit[1] == version:
            return hit[2]
        running = (key, version)
        task = self.running.get(running)
        if task is None:
            task = asyncio.ensure_future(compute())
            self.running[running] = task
            task.add_done_callback(lambda t: self._finish(key, version, t))
        return await asyncio.shield(task)

    def _finish(self, key, version, task):
        self.running.pop((key, version), None)
        if task.cancelled() or task.exception() is not None:
            return
        now = time.monotonic()
        if len(self.done) >= MAX_ENTRIES:
            self.done = {k: v for k, v in self.done.items() if v[0] > now}
            if len(self.done) >= MAX_ENTRIES:
                self.done.clear()
        self.done[key] = (now + (self.ttl if version is None else self.max_age), version, task.result())
