"""Misc parsing helpers used by the reporting pipeline."""


def parse_duration(text):
    """Parse a duration like '2h', '45m', '1h30m', or '90' into total minutes."""
    text = text.strip().lower()
    total = 0
    if "h" in text:
        hours, _, rest = text.partition("h")
        total += int(hours) * 60
        text = rest
    if text.endswith("m"):
        total += int(text.rstrip("m"))
    return total


def format_bytes(n):
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}TB"
