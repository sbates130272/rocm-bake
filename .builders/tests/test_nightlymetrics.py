"""Does nightlymetrics attribute a vertex once, however often it is reported?

That is the claim the per-target table rests on and the one it got
wrong for four months. BuildKit's plain progress re-emits a `DONE` line
for a vertex each time another build request resolves against it, with
the elapsed figure rising each time; summing the lines counted the same
work repeatedly. On the 2026-11-18 nightly that read 1215.2
vertex-seconds inside a 404.0s build, and put `vllm-wheel` at 880.9s
inside its own 203s. Two editions of `.aws-analysis/aws-analysis.md`
quoted those numbers before anyone noticed they were impossible.

The fix is a reduction keyed on (vertex id, label), and the reason it
needs a test rather than a comment is that the obvious key is wrong in
a way no single example shows. There are two shapes of repetition and
only the label separates them:

    one vertex, many DONE lines, one label     -> collapse to one
    many vertices sharing an id, one line each -> keep all of them

The second is real: ids restart per bake target, so `#9` in a
fifteen-target bake is fifteen different `.dockerignore` loads. Keying
on id alone -- which §4 of the analysis originally prescribed -- fixes
the first case and silently destroys the second. Both are below.

Synthetic logs, no build, no Docker: it runs in CI beside ruff.

    python3 -I .builders/tests/test_nightlymetrics.py
"""

import sys
import tempfile
from pathlib import Path

# The module under test, found relative to this file rather than from an
# install, so the test runs against the working tree.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import nightlymetrics  # noqa: E402


def parse_text(text: str) -> dict:
    with tempfile.TemporaryDirectory() as d:
        log = Path(d) / "phase.log"
        log.write_text(text)
        return nightlymetrics.parse([log])


def check(what: str, got, want) -> None:
    if got != want:
        raise AssertionError(f"{what}: got {got!r}, want {want!r}")
    print(f"  ok  {what} = {got!r}")


def test_repeated_done_counts_once() -> None:
    """One vertex, nineteen DONE lines, rising elapsed -> the maximum.

    Shaped on `#240 [vllm-wheel builder 14/14]` from the 2026-11-18
    warm log, which is where the bug was found.
    """
    lines = ["#240 [vllm builder 14/14] RUN ls -la /wheels/"]
    for elapsed in (31.7, 34.9, 35.5, 40.6, 59.4):
        lines.append("#240 [vllm-wheel builder 14/14] RUN ls -la /wheels/")
        lines.append(f"#240 DONE {elapsed}s")
    d = parse_text("\n".join(lines) + "\n")

    # 59.4, not 202.1: the lines are one vertex re-reported, and the
    # elapsed figure is cumulative rather than incremental.
    check("vertex_seconds", d["vertex_seconds"], 59.4)
    check("vllm-wheel seconds", d["targets"]["vllm-wheel"]["seconds"], 59.4)
    check("vllm-wheel steps", d["targets"]["vllm-wheel"]["steps"], 1)

    # `done` stays a raw line count. Four months of runs.json are
    # expressed in it, so it is deliberately not reduced.
    check("done (raw lines)", d["layer_cache"]["done"], 5)


def test_shared_id_across_targets_counts_separately() -> None:
    """Different targets' vertices that happen to share an id stay distinct.

    This is the case `max` per id alone would destroy. Each target loads
    its own .dockerignore, each is genuinely #9, each takes 0.1s; the
    answer is 0.3s and three steps, not 0.1s and one.
    """
    lines = []
    for target in ("aiter-wheel", "cupy-wheel", "nixl-wheel"):
        lines.append(f"#9 [{target} internal] load .dockerignore")
        lines.append("#9 DONE 0.1s")
    d = parse_text("\n".join(lines) + "\n")

    check("vertex_seconds", d["vertex_seconds"], 0.3)
    for target in ("aiter-wheel", "cupy-wheel", "nixl-wheel"):
        check(f"{target} seconds", d["targets"][target]["seconds"], 0.1)
        check(f"{target} steps", d["targets"][target]["steps"], 1)


def test_build_steps_count_labels_not_lines() -> None:
    """The headline pair is unaffected, and a shared stage is credited twice.

    `build_steps` and `build_steps_cached` were already counting
    distinct labels, which is why §1 of the analysis survived the bug.
    Here: two real steps, one cached, reported four times between them.

    This also pins the one case the reduction cannot collapse -- a
    vertex reported under two target prefixes -- and asserts the
    convention rather than leaving it to be rediscovered.
    """
    text = """\
#12 [vllm builder 3/14] RUN pip install -r requirements.txt
#12 DONE 4.0s
#12 [vllm-wheel builder 3/14] RUN pip install -r requirements.txt
#12 DONE 7.5s
#13 [vllm builder 4/14] RUN python setup.py bdist_wheel
#13 CACHED
#13 [vllm builder 4/14] RUN python setup.py bdist_wheel
#13 CACHED
#20 [vllm internal] load build definition
#20 DONE 0.1s
"""
    d = parse_text(text)

    # Three step labels: 3/14 under two prefixes, plus 4/14. The
    # "internal" vertex carries no n/m position and is excluded, because
    # it can never report CACHED and would only pad the denominator.
    check("build_steps", d["layer_cache"]["build_steps"], 3)
    check("build_steps_cached", d["layer_cache"]["build_steps_cached"], 1)

    # A STAGE SHARED BETWEEN TARGETS IS CREDITED TO EACH REQUESTER, so
    # 4.0 under [vllm] and 7.5 under [vllm-wheel] both count: 11.5, plus
    # 0.1 for the internal load. The alternative is to reduce on id
    # alone, which cannot be done -- test_shared_id_across_targets shows
    # why -- so this is a convention, not an accident, and it is the one
    # `build_steps` already uses: the same stage counts as two steps
    # above for the same reason.
    #
    # The consequence, which anyone reading the table needs to know: in
    # a build with shared stages the per-target column sums to MORE than
    # wall vertex time. It is a share-of-attention figure, not a
    # partition of the clock. (On the 2026-11-18 log the two coincide,
    # 452.6 either way, because no vertex there had DONE lines under
    # more than one prefix.)
    check("vertex_seconds", d["vertex_seconds"], 11.6)
    check("vllm seconds", d["targets"]["vllm"]["seconds"], 4.1)
    check("vllm-wheel seconds", d["targets"]["vllm-wheel"]["seconds"], 7.5)

    # CACHED is reduced the same way: two lines, one vertex, one credit.
    check("vllm cached", d["targets"]["vllm"]["cached"], 1)


def test_per_target_seconds_reconcile() -> None:
    """Every attributed second lands in exactly one target.

    The sum of the per-target table must equal vertex_seconds when
    nothing is unattributed -- that is what makes the table readable as
    a share of the build rather than a set of unrelated figures.
    """
    text = """\
#5 [pytorch builder 2/9] RUN cmake --build .
#5 DONE 3.2s
#5 [pytorch builder 2/9] RUN cmake --build .
#5 DONE 5.6s
#8 [triton-wheel builder 2/6] RUN pip wheel .
#8 DONE 2.0s
#9 [internal] load metadata
#9 DONE 1.0s
"""
    d = parse_text(text)

    check("pytorch seconds", d["targets"]["pytorch"]["seconds"], 5.6)
    check("triton-wheel seconds", d["targets"]["triton-wheel"]["seconds"], 2.0)
    # A bare "[internal]" label has no target, so it is held aside
    # rather than dropped; vertex_seconds still means all vertex time.
    check("unattributed_seconds", d["unattributed_seconds"], 1.0)
    check("vertex_seconds", d["vertex_seconds"], 8.6)
    check(
        "table reconciles",
        round(sum(t["seconds"] for t in d["targets"].values()), 1)
        + d["unattributed_seconds"],
        d["vertex_seconds"],
    )


def main() -> int:
    tests = [
        test_repeated_done_counts_once,
        test_shared_id_across_targets_counts_separately,
        test_build_steps_count_labels_not_lines,
        test_per_target_seconds_reconcile,
    ]
    failed = 0
    for test in tests:
        print(f"{test.__name__}:")
        try:
            test()
        except AssertionError as exc:
            print(f"  FAIL  {exc}")
            failed += 1
    if failed:
        print(f"\n{failed} of {len(tests)} failed")
        return 1
    print(f"\n{len(tests)} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
