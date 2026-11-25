#!/usr/bin/env python3
"""docker/max-jobs.sh decides how wide every compile in this repo runs.

It replaced nine hand-rolled copies of the same arithmetic, which had
drifted into nine variants; see the header of the script. These cases
are the ones those variants disagreed about, plus the measurement that
sent four nightlies to an OOM-killed host.
"""
import subprocess
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "docker" / "max-jobs.sh"


def run(per, reserve=None, ceiling=None, *, avail_gb=None, cores=None,
        meminfo=None, tmp=None):
    """Call the script against a synthetic node. Returns (jobs, stderr)."""
    argv = [str(SCRIPT), str(per)]
    if reserve is not None:
        argv.append(str(reserve))
    if ceiling is not None:
        argv.append(str(ceiling))

    env = {"PATH": "/usr/bin:/bin"}
    if cores is not None:
        env["NPROC"] = str(cores)
    if meminfo is not None:
        env["MEMINFO"] = str(meminfo)
    elif avail_gb is not None:
        p = tmp / "meminfo"
        p.write_text(f"MemTotal: 99999999 kB\n"
                     f"MemAvailable: {int(avail_gb * 1048576)} kB\n")
        env["MEMINFO"] = str(p)

    r = subprocess.run(argv, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise AssertionError(f"exit {r.returncode}: {r.stderr}")
    return int(r.stdout.strip()), r.stderr


class MaxJobs(unittest.TestCase):
    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_the_run_that_broke_the_host(self):
        """2026-11-25: 48 cores, 91GB, Triton at 2GB a job.

        Unguarded this derived 45 and the host ran out of memory so
        completely that `tail` could not allocate. The reserve alone
        does not save it -- it still says 39 -- which is why there is
        also a ceiling.
        """
        bare, _ = run(2, avail_gb=91, cores=48, tmp=self.tmp)
        self.assertEqual(bare, 45, "unguarded arithmetic should still be 45")

        reserved, _ = run(2, 12, avail_gb=91, cores=48, tmp=self.tmp)
        self.assertEqual(reserved, 39, "a reserve alone is not enough here")

        guarded, _ = run(2, 12, 8, avail_gb=91, cores=48, tmp=self.tmp)
        self.assertEqual(guarded, 8)

    def test_the_reserve_does_not_swallow_a_small_node(self):
        """snoc-gaming: 16 cores, 13GB available.

        A flat 12GB reserve is over nine tenths of this node and took
        it from 6 jobs to 1 -- a 16-core machine effectively removed
        from the fleet. Measured on the first fleet build after this
        script landed, where it got one target and 2% mean CPU.

        The same reserve on a 122GB node must stay exactly 12.
        """
        small, err = run(2, 12, 8, avail_gb=13, cores=16, tmp=self.tmp)
        self.assertGreater(small, 1, "a 16-core node must not drop to 1 job")
        self.assertEqual(small, 4, "(13 - 13/4) / 2")
        # The log line reports what was held back, not what was asked.
        self.assertIn("3.2GB held back", err)
        self.assertNotIn("12GB held back", err)

        # cores=64 so the core clamp does not hide the arithmetic
        big, _ = run(2, 12, 99, avail_gb=122, cores=64, tmp=self.tmp)
        self.assertEqual(big, 55, "(122-12)/2, so the reserve is untouched")

    def test_the_github_runner_that_timed_out(self):
        """4 cores, 14.5GB, vllm-cpu at 3GB a job with no reserve.

        This runner built vllm-cpu at 4 jobs for months. A reserve
        capped at half the node cut it to 2, the build took 40 minutes
        instead of about 22, and the CPU lane hit its 60-minute limit
        (PR #68). Dockerfile.vllm-cpu now passes a reserve of 0.
        """
        n, _ = run(3, 0, 8, avail_gb=14.5, cores=4, tmp=self.tmp)
        self.assertEqual(n, 4)

    def test_cores_bound_a_small_memory_rich_node(self):
        bare, _ = run(1, avail_gb=256, cores=4, tmp=self.tmp)
        self.assertEqual(bare, 4, "never more jobs than cores")

    def test_never_zero_or_negative(self):
        """A reserve larger than the node must not yield 0 or -1.

        `make -j0` is unbounded parallelism and `-j-1` is an error;
        either would be worse than the bug being guarded against.
        """
        for avail in (12, 10, 1, 0):
            n, _ = run(2, 12, 8, avail_gb=avail, cores=8, tmp=self.tmp)
            self.assertGreaterEqual(n, 1, f"{avail}GB available gave {n}")
        # Where the node is genuinely too small to divide, it is 1.
        for avail in (1, 0):
            n, _ = run(2, 12, 8, avail_gb=avail, cores=8, tmp=self.tmp)
            self.assertEqual(n, 1)

    def test_per_job_of_zero_does_not_divide_by_zero(self):
        n, _ = run(0, 12, 8, avail_gb=91, cores=48, tmp=self.tmp)
        self.assertEqual(n, 1)

    def test_unreadable_meminfo_falls_back_to_one_not_to_cores(self):
        """The one case where guessing wide is worst.

        Eight of the nine replaced copies fell back to `nproc` here,
        which on the AWS runner would be 48 jobs on a node whose memory
        could not be read.
        """
        n, _ = run(2, 12, 8, meminfo=self.tmp / "does-not-exist", cores=48)
        self.assertEqual(n, 1)

    def test_ceiling_is_optional(self):
        n, _ = run(2, 12, avail_gb=91, cores=48, tmp=self.tmp)
        self.assertEqual(n, 39, "no ceiling argument means no ceiling")
        n, _ = run(2, 12, 0, avail_gb=91, cores=48, tmp=self.tmp)
        self.assertEqual(n, 39, "a ceiling of 0 means no ceiling")

    def test_reserve_is_optional(self):
        n, _ = run(2, avail_gb=91, cores=48, tmp=self.tmp)
        self.assertEqual(n, 45)

    def test_explains_itself_on_stderr(self):
        """The build log has to say what was chosen and why.

        Four nightlies failed without recording the job count, which is
        part of why the cause took four runs to find.
        """
        _, err = run(2, 12, 8, avail_gb=91, cores=48, tmp=self.tmp)
        for fragment in ("max-jobs: 8", "48 cores", "91", "12.0GB held back",
                         "ceiling 8"):
            self.assertIn(fragment, err)

    def test_missing_per_job_argument_fails_loudly(self):
        r = subprocess.run([str(SCRIPT)], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("usage", r.stderr.lower())


if __name__ == "__main__":
    print(textwrap.dedent(__doc__))
    unittest.main(verbosity=2)
