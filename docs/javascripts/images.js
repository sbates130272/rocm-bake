/* Render published image sizes on the image-sizes page.
 *
 * Same arrangement as bench.js and for the same reason: the numbers
 * come from the Zot registry on the fleet, which a GitHub-hosted runner
 * cannot reach, so `make image-publish` pushes data/images.json onto
 * gh-pages and this fetches it at runtime.
 *
 * Shape of data/images.json (see .builders/imagesizes.py):
 *   { generated, registry, images[], wheels[], caches[], history[] }
 * where an image is
 *   { repo, tag, arch, pushed, tags, bytes, shared_bytes, own_bytes,
 *     layers: [{ digest, bytes, shared }] }
 *
 * The split into shared and own is the whole point of the page. Every
 * run image here is mostly one ROCm SDK layer that all of them carry,
 * so a chart of totals would say "vLLM is the big one" when vLLM's own
 * contribution is under a gigabyte. Stacking the two makes the base
 * image's share impossible to misread.
 */

(function () {
  "use strict";

  // Site root is not knowable from here — Pages serves from
  // /rocm-bake/, `mkdocs serve` from /, dist/site from a file:// path.
  const CANDIDATES = [
    "../data/images.json",
    "../../data/images.json",
    "data/images.json",
    "/rocm-bake/data/images.json",
    "/data/images.json",
  ];

  const SHARED_COLOUR = "#b3443b";
  const OWN_COLOUR = "#2a9d8f";

  function gb(bytes) {
    if (bytes == null) return "–";
    return (bytes / 1e9).toFixed(2) + " GB";
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
    el.innerHTML = '<p class="bench-empty">' + text + "</p>";
  }

  function renderTable(el, data) {
    const rows = data.images || [];
    if (!rows.length) {
      note(el, "No image sizes have been published yet.");
      return;
    }
    let html =
      "<table><thead><tr><th>image</th><th>tag</th><th>arch</th>" +
      "<th>total</th><th>shared</th><th>own</th><th>pushed</th>" +
      "</tr></thead><tbody>";
    for (const r of rows) {
      html +=
        "<tr><td><code>" +
        r.repo +
        "</code></td><td><code>" +
        r.tag +
        "</code></td><td><code>" +
        (r.arch || "–") +
        "</code></td><td>" +
        gb(r.bytes) +
        "</td><td>" +
        gb(r.shared_bytes) +
        "</td><td><strong>" +
        gb(r.own_bytes) +
        "</strong></td><td>" +
        (r.pushed || "–").replace("T", " ").slice(0, 16) +
        "</td></tr>";
    }
    html += "</tbody></table>";
    el.innerHTML = html;
  }

  function renderSplit(canvas, data) {
    const rows = (data.images || []).filter((r) => r.bytes > 0);
    if (!rows.length || typeof Chart === "undefined") return false;

    // Horizontal, because the labels are repository names and five of
    // them rotated 45° under a vertical chart is the usual way this
    // kind of plot becomes unreadable.
    new Chart(canvas, {
      type: "bar",
      data: {
        labels: rows.map((r) => r.repo),
        datasets: [
          {
            label: "shared with other images",
            backgroundColor: SHARED_COLOUR,
            data: rows.map((r) => (r.shared_bytes || 0) / 1e9),
          },
          {
            label: "this image's own layers",
            backgroundColor: OWN_COLOUR,
            data: rows.map((r) => (r.own_bytes || 0) / 1e9),
          },
        ],
      },
      options: {
        indexAxis: "y",
        responsive: true,
        scales: {
          x: {
            stacked: true,
            title: { display: true, text: "compressed size (GB)" },
          },
          y: { stacked: true },
        },
        plugins: {
          tooltip: {
            callbacks: {
              label: (c) =>
                c.dataset.label + ": " + c.parsed.x.toFixed(2) + " GB",
            },
          },
        },
      },
    });
    return true;
  }

  function renderHistory(canvas, data) {
    const points = data.history || [];
    if (points.length < 2 || typeof Chart === "undefined") return false;

    // Every repo that appears in any snapshot gets a line, so an image
    // that was added or removed partway through shows as a line that
    // starts or stops rather than silently rescaling the others.
    const repos = [
      ...new Set(
        points.flatMap((p) => (p.images || []).map((i) => i.repo))
      ),
    ].sort();
    if (!repos.length) return false;

    // x is the snapshot's position, not its timestamp — `make
    // image-publish` is run by hand, so the points cluster and a time
    // axis renders them as a smear. The date stays in the tooltip.
    const labels = points.map((p) => (p.generated || "").slice(0, 10));

    new Chart(canvas, {
      type: "line",
      data: {
        labels: labels,
        datasets: repos.map(function (repo, n) {
          return {
            label: repo,
            borderColor: `hsl(${(n * 67) % 360} 55% 45%)`,
            backgroundColor: `hsl(${(n * 67) % 360} 55% 45%)`,
            tension: 0.1,
            data: points.map(function (p) {
              const hit = (p.images || []).find((i) => i.repo === repo);
              return hit ? hit.bytes / 1e9 : null;
            }),
          };
        }),
      },
      options: {
        responsive: true,
        spanGaps: false,
        scales: {
          y: { title: { display: true, text: "compressed size (GB)" } },
        },
        plugins: {
          tooltip: {
            callbacks: {
              label: (c) =>
                c.dataset.label + ": " + (c.parsed.y ?? 0).toFixed(2) + " GB",
            },
          },
        },
      },
    });
    return true;
  }

  function renderCaches(el, data) {
    const rows = data.caches || [];
    if (!rows.length) {
      el.remove();
      return;
    }
    let total = 0;
    let html =
      "<table><thead><tr><th>cache repo</th><th>tags</th>" +
      "<th>summed over tags</th></tr></thead><tbody>";
    for (const r of rows) {
      total += r.bytes || 0;
      html +=
        "<tr><td><code>" +
        r.repo +
        "</code></td><td>" +
        r.tags +
        "</td><td>" +
        gb(r.bytes) +
        "</td></tr>";
    }
    html +=
      "</tbody><tfoot><tr><th>total</th><th></th><th>" +
      gb(total) +
      "</th></tr></tfoot></table>";
    el.innerHTML = html;
  }

  async function init() {
    const tableEl = document.getElementById("images-table");
    const splitEl = document.getElementById("images-split");
    const histEl = document.getElementById("images-history");
    const cacheEl = document.getElementById("images-caches");
    const stampEl = document.getElementById("images-generated");
    if (!tableEl && !splitEl && !histEl && !cacheEl) return;

    const data = await load();
    if (!data) {
      const msg =
        "No image sizes are published yet. Run <code>make image-data</code> " +
        "on the registry host, then <code>make image-publish PUSH=1</code>.";
      if (tableEl) note(tableEl, msg);
      if (splitEl) splitEl.parentElement.remove();
      if (histEl) histEl.parentElement.remove();
      if (cacheEl) cacheEl.remove();
      return;
    }

    if (stampEl && data.generated) {
      stampEl.textContent =
        "Read from " + (data.registry || "the registry") +
        " on " + data.generated + ".";
    }
    if (tableEl) renderTable(tableEl, data);
    if (splitEl && !renderSplit(splitEl, data)) splitEl.parentElement.remove();
    if (histEl && !renderHistory(histEl, data)) histEl.parentElement.remove();
    if (cacheEl) renderCaches(cacheEl, data);
  }

  // Material loads pages without a full reload, so DOMContentLoaded
  // alone misses every navigation after the first.
  if (window.document$ && typeof window.document$.subscribe === "function") {
    window.document$.subscribe(init);
  } else {
    document.addEventListener("DOMContentLoaded", init);
  }
})();
