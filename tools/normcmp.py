import sys


def norm(line):
    line = line.replace("\\", "/")
    if line.startswith("./"):
        line = line[2:]
    return line


def main():
    a = sorted(norm(x) for x in open(sys.argv[1]).read().splitlines())
    b = sorted(norm(x) for x in open(sys.argv[2]).read().splitlines())
    print("zg", len(a), "rg", len(b), "MATCH" if a == b else "DIFF")
    if a != b:
        sa, sb = set(a), set(b)
        print("only zg", len(sa - sb), "only rg", len(sb - sa))
        for x in list(sb - sa)[:3]:
            print("RG ONLY:", repr(x))
        for x in list(sa - sb)[:3]:
            print("ZG ONLY:", repr(x))


main()
