import sys


def main() -> None:
    state = 0
    for line in sys.stdin:
        if "Instr" in line and "wid=3" in line:
            print(line, end="")
            state = 1
        if state == 1:
            print(line, end="")
            if "Register state" in line:
                state = 2
            elif not "DEBUG" in line:
                state = 0
        elif state == 2:
            if not "%r" in line:
                state = 0
                continue
            print(line, end="")


if __name__ == "__main__":
    main()
