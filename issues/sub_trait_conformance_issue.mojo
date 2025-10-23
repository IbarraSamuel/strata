# Define some trait required to build a struct AStruct
trait A:
    fn a(self):
        ...


# This struct is possible if types conforms to A
struct AStruct[*Ts: A]:
    ...


# Add another dummy trait
trait OtherTrait:
    ...


alias B = A & OtherTrait


# My second struct Bstruct requires A + OtherTrait
# This is ok, since B inherits from A, then AStruct is possible.
struct BStruct[t: B]:
    var a_value: AStruct[t, t, t]


# When I want to use B trait as A trait, it fails. But B has A right?
struct BVariadicStruct[*Ts: B]:
    var a_values: AStruct[
        *Ts
    ]  # ISSUE: 'AStruct' parameter #0 has 'Variadic[A]' type, but value has type 'Variadic[A & OtherTrait]'
    pass


# Why is it a problem?


# Works again.
struct AOnly[*Ts: A]:
    var a_values: AStruct[*Ts]
