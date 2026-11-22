"""Minimal end-to-end Strata v2 pipeline example."""

from strata import pipeline


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
    var parse = pipeline.Fn(parse_int)
    var dbl = pipeline.Fn(double_val)
    var itof = pipeline.Fn(to_float)
    var fmt = pipeline.Fn(merge)

    var graph = parse | (dbl & itof) | fmt
    print(graph("14"))  # 42.0
