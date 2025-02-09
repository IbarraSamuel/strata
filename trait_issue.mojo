trait A:
    fn a(self):
        ...


struct ASt[*Ts: A]:
    ...


trait B(A):
    ...


# This is ok, since B inherits from A
struct Bsingle[t: B]:
    var a_value: ASt[t]


# This fails. Should happen?
struct Bmultiple[*Ts: B]:
    var a_values: ASt[*Ts]


# Works again.
struct Aonly[*Ts: A]:
    var a_values: ASt[*Ts]
