#!/usr/bin/env python3
"""The real-RAW regression suite's test list, read and checked (docs/ci-regression.md).

    regression.py modules LIST              the test modules LIST's tests are in
    regression.py filter LIST [MODULE]      the `swift test --filter` regex for LIST's tests
                                            (only MODULE's, if given)
    regression.py check LIST LOG XUNIT...   exit 1 unless every test LIST requires ran and
                                            passed in the XUNIT reports, nothing there was
                                            skipped, and LOG holds every line LIST expects
    regression.py unlisted LIST TESTS       exit 1 naming each test of a *SampleTests suite in
                                            the Swift sources under TESTS that LIST neither
                                            requires nor excludes

LIST is scripts/regression-tests.txt; each XUNIT a Swift Testing report `swift test
--xunit-output` writes (its `-swift-testing.xml` file); LOG the run's output. SwiftPM runs each
test module in its own process, and each overwrites the same report, so scripts/regression.sh
runs one module at a time with a report each.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def read_list(path):
    tests, excluded, outputs = [], {}, []
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            kind, _, rest = line.partition(" ")
            rest = rest.strip()
            if kind == "test" and rest and " " not in rest:
                tests.append(rest)
            elif kind == "exclude" and rest:
                test, _, why = rest.partition(" ")
                excluded[test] = why.strip()
            elif kind == "output" and rest:
                outputs.append(rest)
            else:
                raise SystemExit(f"error: {path}:{number}: cannot read {line!r}")
    problems = [f"{t} is listed twice" for t in set(tests) if tests.count(t) > 1]
    problems += [f"{t} is both required and excluded" for t in tests if t in excluded]
    problems += [f"{t} is not a test id (Module.Suite/test())" for t in tests
                 if not re.fullmatch(r"[A-Za-z_]\w*\.[\w.]+/\w+\(.*\)", t)]
    if not tests:
        problems.append("no tests")
    if problems:
        raise SystemExit(f"error: {path}: " + "; ".join(problems))
    return tests, excluded, outputs


def filter_regex(tests):
    # Swift Testing does not match ^ and $ against the whole id; the module prefix and the
    # escaped parentheses keep each alternative to its own test.
    return "|".join(re.escape(t) for t in tests)


def module(test):
    return test.split(".", 1)[0]


def source_tests(tests_dir):
    """Every test in the Swift sources under TESTS_DIR (a folder a module), named as `swift test
    list` names it, Module.Suite/name(labels:): each `@Test` function under the last type or
    extension declared at the start of a line."""
    found = []
    for path in sorted(Path(tests_dir).glob("*/*.swift")):
        suite, pending = None, False
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            top = None if line[:1].isspace() or line.startswith(("/", "*")) else \
                re.search(r"\b(?:struct|class|enum|actor|extension)\s+(\w+)", line)
            if top:
                suite, pending = top[1], False
            if re.match(r"\s*@Test\b", line):
                pending = True
            name = re.search(r"\bfunc (\w+)\s*\(", line) if pending else None
            if not name:
                continue
            # The parameters to the closing parenthesis, split at the commas outside brackets.
            text, depth, params = "\n".join(lines[i:])[line.index(name[0]) + len(name[0]):], 1, ""
            for c in text:
                depth += (c in "([<") - (c in ")]>")
                if depth == 0:
                    break
                params += c if depth > 1 or c != "," else "\0"
            labels = "".join(p.split()[0].rstrip(":") + ":" for p in params.split("\0") if p.strip())
            found.append(f"{path.parent.name}.{suite}/{name[1]}({labels})")
            pending = False
    return found


def unlisted(list_path, tests_dir):
    tests, excluded, _ = read_list(list_path)
    missing = [t for t in source_tests(tests_dir)
               if re.search(r"\.\w*SampleTests/", t) and t not in tests and t not in excluded]
    for test in missing:
        print(f"error: {test} is in a sample suite but {list_path} neither requires nor excludes it",
              file=sys.stderr)
    return 1 if missing else 0


def check(list_path, log_path, xunit_paths):
    tests, excluded, outputs = read_list(list_path)
    cases = []
    for path in xunit_paths:
        try:
            cases += ET.parse(path).getroot().iter("testcase")
        except (OSError, ET.ParseError) as error:
            print(f"error: no readable test report at {path}: {error}", file=sys.stderr)
            return 1
    seen = {}
    for case in cases:
        test = f"{case.get('classname')}/{case.get('name')}"
        if case.find("skipped") is not None:
            state = "skipped"
        elif case.find("failure") is not None or case.find("error") is not None:
            state = "failed"
        else:
            state = "passed"
        # A parameterised test may report a case per argument; any bad one counts.
        if seen.get(test) in (None, "passed"):
            seen[test] = state
    with open(log_path, encoding="utf-8", errors="replace") as f:
        log = f.read()

    problems = []
    for test in tests:
        state = seen.get(test)
        if state is None:
            problems.append(f"required test did not run: {test}")
        elif state != "passed":
            problems.append(f"required test {state}: {test}")
    for test, state in sorted(seen.items()):
        if test not in tests and state != "passed":
            problems.append(f"test in the run {state}: {test}")
        if test in excluded:
            problems.append(f"excluded test ran: {test} ({excluded[test]})")
    for text in outputs:
        if text not in log:
            problems.append(f"the run never printed {text!r}")

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(f"error: real-RAW regression suite: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    print(f"real-RAW regression suite: {len(tests)} required tests ran and passed "
          f"({len(seen)} in the report), {len(outputs)} expected lines printed, "
          f"{len(excluded)} excluded")
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "modules":
        print("\n".join(sorted({module(t) for t in read_list(argv[2])[0]})))
        return 0
    if len(argv) in (3, 4) and argv[1] == "filter":
        tests = read_list(argv[2])[0]
        print(filter_regex([t for t in tests if len(argv) == 3 or module(t) == argv[3]]))
        return 0
    if len(argv) == 4 and argv[1] == "unlisted":
        return unlisted(argv[2], argv[3])
    if len(argv) >= 5 and argv[1] == "check":
        return check(argv[2], argv[3], argv[4:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
