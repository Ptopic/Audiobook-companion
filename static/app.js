let currentBook = null;
let currentJob = null;
let pollTimer = null;

const $ = (id) => document.getElementById(id);

$("speed").addEventListener("input", () => {
  $("speedOut").textContent = Number($("speed").value).toFixed(1);
});

loadVoices();

$("file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const data = new FormData();
  data.append("file", file);
  $("bookMeta").textContent = "Parsing EPUB...";
  const res = await fetch("/api/books", { method: "POST", body: data });
  if (!res.ok) {
    $("bookMeta").textContent = await res.text();
    return;
  }
  currentBook = await res.json();
  renderBook();
});

$("generate").addEventListener("click", async () => {
  if (!currentBook) return;
  const include = [...document.querySelectorAll(".chapter input:checked")].map((el) => el.value);
  if (include.length === 0) {
    $("status").textContent = "Select at least one chapter to generate.";
    return;
  }
  const replacements = {};
  $("replacements").value.split(/\n+/).forEach((line) => {
    const idx = line.indexOf("=");
    if (idx > 0) replacements[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
  });
  const payload = {
    engine: $("engine").value,
    voice: $("voice").value,
    speed: Number($("speed").value),
    include_chapters: include,
    replacements
  };
  const res = await fetch(`/api/books/${currentBook.id}/jobs`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
  if (!res.ok) {
    $("status").textContent = await res.text();
    return;
  }
  const body = await res.json();
  currentJob = body.job_id;
  $("cancel").disabled = false;
  $("resume").disabled = true;
  $("generate").disabled = true;
  pollJob();
});

$("preview").addEventListener("click", async () => {
  if (!currentBook) return;
  const checked = document.querySelector(".chapter input:checked");
  const chapter = currentBook.chapters.find((c) => c.id === (checked ? checked.value : currentBook.chapters[0].id));
  const payload = {
    text: (chapter ? chapter.text : "Preview").slice(0, 500),
    engine: $("engine").value,
    voice: $("voice").value,
    speed: Number($("speed").value)
  };
  const res = await fetch("/api/preview", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
  if (!res.ok) {
    $("status").textContent = await res.text();
    return;
  }
  const blob = await res.blob();
  $("previewAudio").src = URL.createObjectURL(blob);
  $("previewAudio").hidden = false;
  $("previewAudio").play();
});

$("cancel").addEventListener("click", async () => {
  if (currentJob) await fetch(`/api/jobs/${currentJob}/cancel`, { method: "POST" });
});

$("resume").addEventListener("click", async () => {
  if (!currentJob) return;
  await fetch(`/api/jobs/${currentJob}/resume`, { method: "POST" });
  $("cancel").disabled = false;
  $("resume").disabled = true;
  pollJob();
});

$("deleteBook").addEventListener("click", async () => {
  if (!currentBook) return;
  await fetch(`/api/books/${currentBook.id}`, { method: "DELETE" });
  currentBook = null;
  currentJob = null;
  $("bookMeta").textContent = "Book data deleted from local storage.";
  $("chapters").innerHTML = "";
  $("players").innerHTML = "";
  $("export").hidden = true;
  $("iphonePackage").hidden = true;
  $("iphoneManifest").hidden = true;
  $("uploadS3").hidden = true;
  $("generate").disabled = true;
  $("preview").disabled = true;
  $("deleteBook").disabled = true;
});

$("uploadS3").addEventListener("click", async () => {
  if (!currentJob) return;
  $("cloudStatus").textContent = "Uploading package to S3...";
  const res = await fetch(`/api/audiobooks/${currentJob}/upload-s3`, { method: "POST" });
  const body = await res.text();
  if (!res.ok) {
    $("cloudStatus").textContent = body;
    return;
  }
  const data = JSON.parse(body);
  $("cloudStatus").innerHTML = `Uploaded. Manifest: <a href="${data.manifest_url}">${data.manifest_url}</a>`;
});

async function loadVoices() {
  const data = await fetch("/api/voices").then((r) => r.json()).catch(() => null);
  if (!data) return;
  const list = $("voices");
  list.innerHTML = "";
  const engineSelect = $("engine");
  engineSelect.innerHTML = "";
  data.engines.forEach((engine) => {
    const option = document.createElement("option");
    option.value = engine.id;
    option.textContent = engine.name;
    engineSelect.append(option);
  });
  engineSelect.value = "kokoro";
  data.engines.flatMap((engine) => engine.voices || []).forEach((voice) => {
    const option = document.createElement("option");
    option.value = voice;
    list.append(option);
  });
}

function renderBook() {
  $("bookMeta").textContent = `${currentBook.title} · ${currentBook.chapters.length} chapters`;
  $("generate").disabled = false;
  $("preview").disabled = false;
  $("deleteBook").disabled = false;
  $("chapters").innerHTML = "";
  currentBook.chapters.forEach((chapter) => {
    const label = document.createElement("label");
    label.className = "chapter";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = false;
    input.value = chapter.id;
    const copy = document.createElement("span");
    const title = document.createElement("strong");
    title.textContent = chapter.title;
    const text = document.createElement("small");
    text.textContent = chapter.text.slice(0, 260);
    copy.append(title, text);
    label.append(input, copy);
    $("chapters").append(label);
  });
}

async function pollJob() {
  if (!currentJob) return;
  clearTimeout(pollTimer);
  const job = await fetch(`/api/jobs/${currentJob}`).then((r) => r.json());
  $("progress").value = job.progress || 0;
  $("status").textContent = `${job.status}: ${job.message || ""}`;
  if (job.status === "done") {
    $("cancel").disabled = true;
    $("resume").disabled = true;
    $("generate").disabled = false;
    renderPlayers(job);
    return;
  }
  if (job.status === "failed" || job.status === "cancelled") {
    $("cancel").disabled = true;
    $("resume").disabled = false;
    $("generate").disabled = false;
    return;
  }
  pollTimer = setTimeout(pollJob, 1000);
}

function renderPlayers(job) {
  $("players").innerHTML = "";
  Object.keys(job.artifacts.chapters || {}).forEach((cid) => {
    const chapter = currentBook.chapters.find((c) => c.id === cid);
    const row = document.createElement("div");
    row.className = "player";
    const name = document.createElement("strong");
    name.textContent = chapter ? chapter.title : cid;
    const audio = document.createElement("audio");
    audio.controls = true;
    audio.src = `/api/jobs/${job.id}/audio/${cid}`;
    row.append(name, audio);
    $("players").append(row);
  });
  $("export").hidden = false;
  $("export").href = `/api/jobs/${job.id}/export`;
  $("iphonePackage").hidden = false;
  $("iphonePackage").href = `/api/audiobooks/${job.id}/package`;
  $("iphoneManifest").hidden = false;
  $("iphoneManifest").href = `/api/audiobooks/${job.id}/manifest`;
  $("uploadS3").hidden = false;
}
