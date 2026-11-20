/* Render build-benchmark data on the performance pages.
 *
 * The data is not built into the site. `make bench-publish` pushes
 * data/bench.json onto the gh-pages branch from a build node, because
 * that is the only place the numbers exist — a GitHub-hosted runner
 * cannot reproduce or even read them. So this fetches at runtime and
 * degrades to a readable message when there is nothing published yet,
 * which is also what a local `mkdocs serve` sees.
 *
 * Shape of data/bench.json (see .builders/bench.sh, `json` mode):
 *   { generated, scenarios[], runs[], summary[] }
 * where a summary row is
 *   { target, builder, arch, max_jobs, scenario, n, median_seconds,
 *     min_seconds, max_seconds }
 *
 * arch is part of the key, not decoration: vLLM's kernel prebuild is
 * ~50 min on gfx950 and hours on gfx1201, so a bar that pooled them
 * would be an average of two different machines' worth of work.
 */

(function () {
  "use strict";

  // The site root is not knowable from here: the page may be served
  // from /rocm-bake/ on Pages, from / under `mkdocs serve`, and from a
  // file:// path out of dist/site. Try the plausible places rather than
  // hard-coding one and breaking the other two.
  const CANDIDATES = [
    "../data/bench.json",
    "../../data/bench.json",
    "data/bench.json",
    "/rocm-bake/data/bench.json",
    "/data/bench.json",
  ];

  // Scenario order and colour are fixed so the same scenario is the
  // same colour on every chart. The ramp runs cheapest to most
  // expensive, which is also the order the scenarios nest in.
  const SCENARIOS = ["frozen", "cold", "warm", "hot"];
  const COLOURS = {
    frozen: "#b3443b",
    cold: "#c97b2e",
    warm: "#2a9d8f",
    hot: "#3f7cac",
  };

  function fmt(seconds) {
    if (seconds == null) return "–";
    if (seconds < 60) return seconds + "s";
    const m = Math.floor(seconds / 60);
    const s = String(seconds % 60).padStart(2, "0");
    if (m < 60) return m + "m" + s + "s";
    return Math.floor(m / 60) + "h" + String(m % 60).padStart(2, "0") + "m";
  }

  async function load() {
    for (const url of CANDIDATES) {
      try {
        const res = await fetch(url, { cache: "no-store" });
        if (res.ok) return await res.json();
      } catch (e) {
        /* try the next candidate */
      }
    }
    return null;
  }

  function note(el, text) {
    el.innerHTML =
      '<p class="bench-empty">' +
      text +
      "</p>";
  }

  function renderSummary(el, data) {
    const rows = data.summary || [];
    if (!rows.length) {
      note(el, "No successful benchmark runs have been published yet.");
      return;
    }

    // One row per (target, builder, jobs), one column per scenario:
    // a reader comparing scenarios is comparing across a row, and a
    // row is only meaningful when the job count matches — see the
    // methodology page on why MAX_JOBS is part of the key.
    const keys = new Map();
    for (const r of rows) {
      const k = [r.target, r.builder, r.arch, r.max_jobs].join("\u0000");
      if (!keys.has(k)) keys.set(k, { r: r, by: {} });
      keys.get(k).by[r.scenario] = r;
    }

    let html =
      "<table><thead><tr><th>target</th><th>builder</th><th>arch</th>" +
      "<th>jobs</th>" +
      SCENARIOS.map((s) => "<th>" + s + "</th>").join("") +
      "</tr></thead><tbody>";
    for (const { r, by } of keys.values()) {
      html +=
        "<tr><td><code>" +
        r.target +
        "</code></td><td>" +
        r.builder +
        "</td><td><code>" +
        (r.arch || "–") +
        "</code></td><td>" +
        (r.max_jobs || "–") +
        "</td>" +
        SCENARIOS.map(function (s) {
          const c = by[s];
          if (!c) return "<td>–</td>";
          const spread = c.n > 1 ? " <small>n=" + c.n + "</small>" : "";
          return "<td>" + fmt(c.median_seconds) + spread + "</td>";
        }).join("") +
        "</tr>";
    }
    html += "</tbody></table>";
    el.innerHTML = html;
  }

  function renderBars(canvas, data) {
    const rows = (data.summary || []).filter((r) => r.median_seconds > 0);
    if (!rows.length || typeof Chart === "undefined") return false;

    // Group by target AND arch, dropping builder and job count: the
    // bar chart is the overview and the table beside it carries the
    // rest. Architecture stays because pooling it would average a
    // gfx950 prebuild with a gfx1201 one, which are different amounts
    // of work rather than two samples of the same thing. Where a
    // target/arch has several keys for one scenario, take the lowest
    // median — the best the fleet has managed under that condition.
    const targets = [
      ...new Set(rows.map((r) => r.target + " " + (r.arch || "?"))),
    ].sort();
    const best = {};
    for (const r of rows) {
      const k = r.target + " " + (r.arch || "?") + "\u0000" + r.scenario;
      if (!(k in best) || r.median_seconds < best[k]) best[k] = r.median_seconds;
    }

    new Chart(canvas, {
      type: "bar",
      data: {
        labels: targets,
        datasets: SCENARIOS.map(function (s) {
          return {
            label: s,
            backgroundColor: COLOURS[s],
            data: targets.map((t) => best[t + "\u0000" + s] ?? null),
          };
        }).filter((d) => d.data.some((v) => v != null)),
      },
      options: {
        responsive: true,
        scales: {
          y: {
            type: "logarithmic",
            title: { display: true, text: "build time (s, log scale)" },
          },
        },
        plugins: {
          tooltip: {
            callbacks: {
              label: (c) => c.dataset.label + ": " + fmt(c.parsed.y),
            },
          },
        },
      },
    });
    return true;
  }

  function renderHistory(canvas, data) {
    const runs = (data.runs || []).filter((r) => r.rc === 0 && r.seconds > 0);
    if (!runs.length || typeof Chart === "undefined") return false;

    // x is the run's position in chronological order, not its
    // timestamp. Runs cluster — a night of benchmarking puts twelve
    // points inside two hours and then nothing for a week — and a time
    // axis renders that as a smear against an empty expanse. The
    // timestamp stays in the tooltip, where it is actually read.
    runs.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
    runs.forEach((r, i) => {
      r._i = i;
    });

    new Chart(canvas, {
      type: "scatter",
      data: {
        datasets: SCENARIOS.map(function (s) {
          return {
            label: s,
            borderColor: COLOURS[s],
            backgroundColor: COLOURS[s],
            data: runs
              .filter((r) => r.scenario === s)
              .map((r) => ({
                x: r._i,
                y: r.seconds,
                t: r.target + " [" + (r.arch || "?") + "]",
                ts: r.ts,
              })),
          };
        }).filter((d) => d.data.length),
      },
      options: {
        responsive: true,
        scales: {
          x: {
            type: "linear",
            title: { display: true, text: "run, oldest first" },
            ticks: { display: false },
          },
          y: {
            type: "logarithmic",
            title: { display: true, text: "build time (s, log scale)" },
          },
        },
        plugins: {
          tooltip: {
            callbacks: {
              label: (c) =>
                c.raw.t +
                " " +
                c.dataset.label +
                ": " +
                fmt(c.raw.y) +
                "  (" +
                c.raw.ts +
                ")",
            },
          },
        },
      },
    });
    return true;
  }

  async function init() {
    const summaryEl = document.getElementById("bench-summary");
    const barsEl = document.getElementById("bench-bars");
    const histEl = document.getElementById("bench-history");
    const stampEl = document.getElementById("bench-generated");
    if (!summaryEl && !barsEl && !histEl) return;

    const data = await load();
    if (!data) {
      const msg =
        "No benchmark data is published yet. Run <code>make bench</code> on " +
        "a build node, then <code>make bench-publish PUSH=1</code>.";
      if (summaryEl) note(summaryEl, msg);
      if (barsEl) barsEl.parentElement.remove();
      if (histEl) histEl.parentElement.remove();
      return;
    }

    if (stampEl && data.generated) {
      stampEl.textContent = "Data generated " + data.generated + ".";
    }
    if (summaryEl) renderSummary(summaryEl, data);
    if (barsEl && !renderBars(barsEl, data)) barsEl.parentElement.remove();
    if (histEl && !renderHistory(histEl, data)) histEl.parentElement.remove();
  }

  // Material loads pages without a full reload, so binding to
  // DOMContentLoaded alone misses every navigation after the first.
  if (window.document$ && typeof window.document$.subscribe === "function") {
    window.document$.subscribe(init);
  } else {
    document.addEventListener("DOMContentLoaded", init);
  }
})();
