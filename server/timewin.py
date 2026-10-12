"""Time. Telemetry is stored in UTC, without a zone; people think in site time. Tools take and
return site time (O_MCP_TZ), and every window is half-open: start included, end excluded, so a
week is start 2026-09-28, end 2026-10-05. A bare date means midnight site time.
"""
import datetime as dt
from dataclasses import dataclass

from .errors import ToolError

UTC = dt.UTC


class BadWindow(ToolError):
    """A tool error the model can act on."""


def today(tz):
    return dt.datetime.now(tz).date()


def parse_date(s, name):
    try:
        return dt.date.fromisoformat(s)
    except (TypeError, ValueError) as e:
        raise BadWindow(f"{name} must be a date, YYYY-MM-DD; got {s!r}.") from e


def parse_local(s, tz, name):
    """A site-time instant from YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]. An explicit offset is honoured."""
    try:
        t = dt.datetime.fromisoformat(s)
    except (TypeError, ValueError) as e:
        raise BadWindow(f"{name} must be YYYY-MM-DD or YYYY-MM-DDTHH:MM in site time; got {s!r}.") from e
    return t.replace(tzinfo=tz) if t.tzinfo is None else t.astimezone(tz)


@dataclass(frozen=True)
class Window:
    start: dt.datetime     # aware, site time
    end: dt.datetime       # aware, site time, excluded

    def utc(self):
        """The bounds as naive UTC, the way telemetry stores time."""
        return (self.start.astimezone(UTC).replace(tzinfo=None), self.end.astimezone(UTC).replace(tzinfo=None))

    def days(self):
        return (self.end - self.start).total_seconds() / 86400

    def as_json(self):
        return {"start": iso(self.start), "end": iso(self.end)}


def window(start, end, tz, max_days, whole_days=False):
    if whole_days:
        s, e = parse_date(start, "start"), parse_date(end, "end")
        w = Window(dt.datetime.combine(s, dt.time(), tz), dt.datetime.combine(e, dt.time(), tz))
    else:
        w = Window(parse_local(start, tz, "start"), parse_local(end, tz, "end"))
    if w.end <= w.start:
        raise BadWindow(f"end ({end}) must be after start ({start}); end is excluded, so one day is "
                        f"start 2026-10-01, end 2026-10-02.")
    if w.days() > max_days:
        raise BadWindow(f"The window is {w.days():.0f} days; this tool takes at most {max_days}. "
                        f"Split it, or ask for a coarser interval over a shorter window.")
    return w


def iso(t):
    return t.isoformat(timespec="minutes")


def local_iso(naive_utc, tz):
    """A naive UTC timestamp from telemetry, as site time with its offset."""
    if naive_utc is None:
        return None
    return iso(naive_utc.replace(tzinfo=UTC).astimezone(tz))
