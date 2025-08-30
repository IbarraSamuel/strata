trait T:
    fn func[t: AnyType](self):
        print("hi")


struct S[t: AnyType](T):
    pass
