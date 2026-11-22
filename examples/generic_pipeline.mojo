"""Minimal end-to-end Strata generic pipeline example."""

from strata import generic


def parse_int(raw: String) -> Int:
    try:
        return Int(raw)
    except:
        return 0


def double_val(x: Int) -> Int:
    return x * 2


def to_float(x: Int) -> Float32:
    return Float32(x)


def merge(pair: Tuple[Int, Float32]) -> String:
    return String(Float32(pair[0]) + pair[1])


def main():
    var parse = generic.Fn(parse_int)
    var dbl = generic.Fn(double_val)
    var itof = generic.Fn(to_float)
    var fmt = generic.Fn(merge)

    var pipeline = parse | (dbl & itof) | fmt
    print(pipeline("14"))  # 42.0
