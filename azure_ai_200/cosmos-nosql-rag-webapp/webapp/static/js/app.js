(() => {
  "use strict";

  // Consistent color per product category, both for the evidence list dots
  // and the vector-space plot nodes. Falls back to a cycling palette for
  // any category not in this fixed list.
  const CATEGORY_CLASSES = {
    "Outdoor & Sports": "cat-1",
    "Home Appliances": "cat-2",
    "Electronics": "cat-3",
    "Fitness & Wellness": "cat-4",
    "Outdoor & Accessories": "cat-5",
  };
  const FALLBACK_CATS = ["cat-1", "cat-2", "cat-3", "cat-4", "cat-5"];
  let fallbackIndex = 0;
  function categoryClass(category) {
    if (CATEGORY_CLASSES[category]) return CATEGORY_CLASSES[category];
    const cls = FALLBACK_CATS[fallbackIndex % FALLBACK_CATS.length];
    fallbackIndex += 1;
    CATEGORY_CLASSES[category] = cls;
    return cls;
  }

  const form = document.getElementById("ask-form");
  const input = document.getElementById("question-input");
  const askButton = document.getElementById("ask-button");
  const btnLabel = askButton.querySelector(".btn-label");
  const btnSpinner = askButton.querySelector(".btn-spinner");
  const topKSelect = document.getElementById("top-k-select");

  const pipeline = document.getElementById("pipeline");
  const errorBanner = document.getElementById("error-banner");
  const results = document.getElementById("results");

  const evidenceList = document.getElementById("evidence-list");
  const evidenceCount = document.getElementById("evidence-count");
  const vectorPlotWrap = document.getElementById("vector-plot-wrap");
  const vectorLegend = document.getElementById("vector-legend");

  const answerText = document.getElementById("answer-text");
  const answerSkeleton = document.getElementById("answer-skeleton");
  const copyBtn = document.getElementById("copy-answer");

  const timingFooter = document.getElementById("timing-footer");
  const timingBar = document.getElementById("timing-bar");
  const timingLegend = document.getElementById("timing-legend");
  const timingTotalValue = document.getElementById("timing-total-value");

  const RECENT_KEY = "cosmos_rag_recent_questions";
  const RECENT_MAX = 6;

  let currentSource = null;

  // ------------------------------------------------------------------
  // Recent questions (client-side only, via localStorage)
  // ------------------------------------------------------------------
  function loadRecent() {
    try {
      return JSON.parse(localStorage.getItem(RECENT_KEY) || "[]");
    } catch {
      return [];
    }
  }

  function saveRecent(question) {
    let recent = loadRecent().filter((q) => q !== question);
    recent.unshift(question);
    recent = recent.slice(0, RECENT_MAX);
    localStorage.setItem(RECENT_KEY, JSON.stringify(recent));
    renderRecent();
  }

  function renderRecent() {
    const recent = loadRecent();
    const wrap = document.getElementById("recent-questions");
    const list = document.getElementById("recent-list");
    if (recent.length === 0) {
      wrap.hidden = true;
      return;
    }
    wrap.hidden = false;
    list.innerHTML = "";
    recent.forEach((q) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = q.length > 46 ? q.slice(0, 46) + "\u2026" : q;
      btn.title = q;
      btn.addEventListener("click", () => {
        input.value = q;
        form.requestSubmit();
      });
      list.appendChild(btn);
    });
  }

  // ------------------------------------------------------------------
  // Example chips
  // ------------------------------------------------------------------
  document.querySelectorAll(".chip").forEach((chip) => {
    chip.addEventListener("click", () => {
      input.value = chip.dataset.q;
      form.requestSubmit();
    });
  });

  // Keyboard shortcut: Cmd/Ctrl+K focuses the question input
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
      e.preventDefault();
      input.focus();
      input.select();
    }
  });

  // ------------------------------------------------------------------
  // Pipeline step UI helpers
  // ------------------------------------------------------------------
  function resetPipeline() {
    ["embedding", "retrieval", "generation"].forEach((name) => {
      const step = document.getElementById(`step-${name}`);
      step.classList.remove("is-active", "is-done", "is-error");
      document.getElementById(`time-${name}`).textContent = "";
    });
  }

  function setStepActive(name) {
    document.getElementById(`step-${name}`).classList.add("is-active");
  }

  function setStepDone(name, ms) {
    const step = document.getElementById(`step-${name}`);
    step.classList.remove("is-active");
    step.classList.add("is-done");
    document.getElementById(`time-${name}`).textContent = `${ms}ms`;
  }

  function setStepError(name) {
    const step = document.getElementById(`step-${name}`);
    step.classList.remove("is-active");
    step.classList.add("is-error");
  }

  // ------------------------------------------------------------------
  // Evidence list (receipt-style line items)
  // ------------------------------------------------------------------
  function renderEvidence(rows) {
    evidenceList.innerHTML = "";
    evidenceCount.textContent = `${rows.length} match${rows.length === 1 ? "" : "es"}`;
    rows.forEach((row, i) => {
      const item = document.createElement("div");
      item.className = "evidence-item";
      item.style.animationDelay = `${i * 60}ms`;

      const dot = document.createElement("div");
      dot.className = `evidence-cat-dot ${categoryClass(row.category)}`;

      const main = document.createElement("div");
      main.className = "evidence-main";
      const stars = "\u2605".repeat(row.reviewRating) + "\u2606".repeat(5 - row.reviewRating);
      main.innerHTML = `
        <div class="evidence-product">${escapeHtml(row.productName)}</div>
        <div class="evidence-meta"><span class="evidence-stars">${stars}</span> &middot; ${escapeHtml(row.category)} &middot; ${escapeHtml(row.transactionDate)}</div>
      `;

      const score = document.createElement("div");
      score.className = "evidence-score";
      score.textContent = row.SimilarityScore.toFixed(3);

      const txn = document.createElement("div");
      txn.className = "evidence-txn";
      txn.textContent = row.transactionId;

      const review = document.createElement("div");
      review.className = "evidence-review";
      review.textContent = `\u201C${row.reviewText}\u201D`;

      item.appendChild(dot);
      item.appendChild(main);
      item.appendChild(score);
      item.appendChild(review);
      item.appendChild(txn);
      evidenceList.appendChild(item);
    });
  }

  // ------------------------------------------------------------------
  // Vector-space plot: query at the center, results arranged radially,
  // distance from center inversely proportional to similarity score.
  // ------------------------------------------------------------------
  function renderVectorPlot(rows) {
    const size = 280;
    const cx = size / 2;
    const cy = size / 2;
    const minR = 34;
    const maxR = 118;

    const scores = rows.map((r) => r.SimilarityScore);
    const lo = Math.min(...scores);
    const hi = Math.max(...scores);
    const spread = hi - lo || 1;

    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("viewBox", `0 0 ${size} ${size}`);

    const nodes = rows.map((row, i) => {
      const angle = (i / rows.length) * Math.PI * 2 - Math.PI / 2;
      const norm = (row.SimilarityScore - lo) / spread; // 0..1, 1 = most similar
      const radius = maxR - norm * (maxR - minR);
      return {
        row,
        x: cx + radius * Math.cos(angle),
        y: cy + radius * Math.sin(angle),
        norm,
      };
    });

    // links first, so nodes draw on top
    nodes.forEach((n) => {
      const line = document.createElementNS(svgNS, "line");
      line.setAttribute("class", "vplot-link");
      line.setAttribute("x1", cx);
      line.setAttribute("y1", cy);
      line.setAttribute("x2", n.x);
      line.setAttribute("y2", n.y);
      line.setAttribute("stroke", "var(--amber)");
      line.setAttribute("stroke-width", 0.6 + n.norm * 2.2);
      line.setAttribute("opacity", 0.25 + n.norm * 0.55);
      svg.appendChild(line);
    });

    // query node
    const qGroup = document.createElementNS(svgNS, "g");
    qGroup.setAttribute("class", "vplot-query");
    const qCircle = document.createElementNS(svgNS, "circle");
    qCircle.setAttribute("cx", cx);
    qCircle.setAttribute("cy", cy);
    qCircle.setAttribute("r", 10);
    qGroup.appendChild(qCircle);
    const qLabel = document.createElementNS(svgNS, "text");
    qLabel.setAttribute("x", cx);
    qLabel.setAttribute("y", cy + 3.5);
    qLabel.setAttribute("text-anchor", "middle");
    qLabel.setAttribute("font-size", "9");
    qLabel.setAttribute("font-family", "JetBrains Mono, monospace");
    qLabel.textContent = "Q";
    qGroup.appendChild(qLabel);
    svg.appendChild(qGroup);

    // result nodes
    nodes.forEach((n) => {
      const g = document.createElementNS(svgNS, "g");
      g.setAttribute("class", `vplot-node ${categoryClass(n.row.category)}`);
      const circle = document.createElementNS(svgNS, "circle");
      circle.setAttribute("cx", n.x);
      circle.setAttribute("cy", n.y);
      circle.setAttribute("r", 6);
      const title = document.createElementNS(svgNS, "title");
      title.textContent = `${n.row.transactionId} \u2014 ${n.row.productName}\nsimilarity ${n.row.SimilarityScore.toFixed(3)}`;
      g.appendChild(circle);
      g.appendChild(title);
      svg.appendChild(g);
    });

    vectorPlotWrap.innerHTML = "";
    vectorPlotWrap.appendChild(svg);

    // legend: unique categories present in this result set
    const seen = new Set();
    vectorLegend.innerHTML = "";
    rows.forEach((row) => {
      if (seen.has(row.category)) return;
      seen.add(row.category);
      const el = document.createElement("span");
      el.innerHTML = `<span class="legend-dot ${categoryClass(row.category)}"></span>${escapeHtml(row.category)}`;
      vectorLegend.appendChild(el);
    });
  }

  // ------------------------------------------------------------------
  // Answer text with [TXN-xxxx] citations highlighted
  // ------------------------------------------------------------------
  function renderAnswer(text) {
    const escaped = escapeHtml(text);
    const highlighted = escaped.replace(/\[?TXN-\d{4}\]?/g, (m) => {
      const clean = m.replace(/[\[\]]/g, "");
      return `<span class="citation">${clean}</span>`;
    });
    answerText.innerHTML = highlighted;
  }

  // ------------------------------------------------------------------
  // Timing footer
  // ------------------------------------------------------------------
  function renderTiming(data) {
    timingFooter.hidden = false;
    const total = data.embedding_ms + data.retrieval_ms + data.generation_ms || 1;
    const segs = [
      { cls: "embedding", label: "vectorize", ms: data.embedding_ms },
      { cls: "retrieval", label: "search", ms: data.retrieval_ms },
      { cls: "generation", label: "answer", ms: data.generation_ms },
    ];
    const colorVar = { embedding: "cyan", retrieval: "amber", generation: "violet" };
    timingBar.innerHTML = "";
    timingLegend.innerHTML = "";
    segs.forEach((seg) => {
      const bar = document.createElement("div");
      bar.className = `timing-seg ${seg.cls}`;
      bar.style.width = `${(seg.ms / total) * 100}%`;
      timingBar.appendChild(bar);

      const legendItem = document.createElement("span");
      legendItem.innerHTML = `<span class="legend-dot" style="background:var(--${colorVar[seg.cls]})"></span>`;
      legendItem.append(` ${seg.label} ${seg.ms}ms`);
      timingLegend.appendChild(legendItem);
    });
    timingTotalValue.textContent = `${data.total_ms}ms`;
  }

  // ------------------------------------------------------------------
  // Misc helpers
  // ------------------------------------------------------------------
  function escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  function showError(stage, message) {
    errorBanner.hidden = false;
    const stageLabel = {
      input: "Input",
      embedding: "Vectorizing",
      retrieval: "Search",
      generation: "Answer generation",
    }[stage] || "Something";
    errorBanner.innerHTML = `<strong>${stageLabel} failed.</strong> ${escapeHtml(message)}`;
    if (stage !== "input") setStepError(stage);
  }

  function setBusy(isBusy) {
    askButton.disabled = isBusy;
    btnLabel.hidden = isBusy;
    btnSpinner.hidden = !isBusy;
  }

  // ------------------------------------------------------------------
  // Main flow
  // ------------------------------------------------------------------
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const question = input.value.trim();
    if (!question) return;

    if (currentSource) currentSource.close();

    // reset UI
    errorBanner.hidden = true;
    results.hidden = true;
    timingFooter.hidden = true;
    answerText.textContent = "";
    copyBtn.hidden = true;
    answerSkeleton.classList.remove("is-active");
    pipeline.hidden = false;
    resetPipeline();
    setBusy(true);

    const topK = topKSelect.value;
    const url = `/api/query?question=${encodeURIComponent(question)}&top_k=${encodeURIComponent(topK)}`;
    const source = new EventSource(url);
    currentSource = source;

    source.onmessage = (event) => {
      const data = JSON.parse(event.data);

      switch (data.step) {
        case "start":
          saveRecent(data.question);
          break;

        case "embedding_start":
          setStepActive("embedding");
          break;

        case "embedding_done":
          setStepDone("embedding", data.duration_ms);
          break;

        case "retrieval_start":
          setStepActive("retrieval");
          break;

        case "retrieval_done":
          setStepDone("retrieval", data.duration_ms);
          results.hidden = false;
          renderEvidence(data.results);
          renderVectorPlot(data.results);
          answerSkeleton.classList.add("is-active");
          break;

        case "generation_start":
          setStepActive("generation");
          break;

        case "generation_done":
          setStepDone("generation", data.duration_ms);
          answerSkeleton.classList.remove("is-active");
          renderAnswer(data.answer);
          copyBtn.hidden = false;
          break;

        case "complete":
          renderTiming(data);
          setBusy(false);
          source.close();
          break;

        case "error":
          showError(data.stage, data.message);
          answerSkeleton.classList.remove("is-active");
          setBusy(false);
          source.close();
          break;

        default:
          break;
      }
    };

    source.onerror = () => {
      // Only surface a generic error if the stream dropped before a
      // clean "complete"/"error" message closed it already.
      if (source.readyState !== EventSource.CLOSED) {
        showError(null, "Lost connection to the server. Check the Flask app is still running.");
      }
      setBusy(false);
      source.close();
    };
  });

  copyBtn.addEventListener("click", () => {
    navigator.clipboard.writeText(answerText.textContent).then(() => {
      copyBtn.textContent = "copied";
      copyBtn.classList.add("copied");
      setTimeout(() => {
        copyBtn.textContent = "copy";
        copyBtn.classList.remove("copied");
      }, 1400);
    });
  });

  renderRecent();
})();
