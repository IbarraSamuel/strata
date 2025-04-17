# ISSUE: type t is not recognized as Defaultable when using the trait union syntax.
fn foo[t: Defaultable & Stringable]():
    # t()  # <-- This triggers the error
