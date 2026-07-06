"""Basic statistics helpers used by the reporting pipeline."""


def mean(values):
    if not values:
        raise ValueError("mean of empty list")
    return sum(values) / len(values)


def median(values):
    if not values:
        raise ValueError("median of empty list")
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid]


def value_range(values):
    if not values:
        raise ValueError("range of empty list")
    return max(values) - min(values)
