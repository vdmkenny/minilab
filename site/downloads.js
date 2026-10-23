// Fills in the Download section from the latest release on GitHub: its version, its date and a
// link to each platform's archive. Without it, the page still links to the latest release.

const repository = "vdmkenny/minilab";

// The builds the release workflow makes, by the end of their file names, in the order to list them.
const platforms = [
  ["macos-aarch64", "macOS · Apple silicon"],
  ["macos-x86_64", "macOS · Intel"],
  ["windows-x86_64", "Windows · x86-64"],
  ["windows-aarch64", "Windows · Arm"],
  ["linux-x86_64", "Linux · x86-64"],
  ["linux-aarch64", "Linux · Arm"],
];

function megabytes(bytes) {
  return `${(bytes / 1e6).toFixed(0)} MB`;
}

function link(href, text) {
  const a = document.createElement("a");
  a.href = href;
  a.textContent = text;
  return a;
}

async function showLatest() {
  const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`);
  if (!response.ok) return;
  const release = await response.json();
  const version = release.tag_name.replace(/^v/, "");
  const date = new Date(release.published_at).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });

  const heading = document.getElementById("release");
  heading.textContent = `Version ${version} · ${date} · `;
  heading.append(link(release.html_url, "Release notes"));

  const files = document.getElementById("files");
  for (const [suffix, label] of platforms) {
    const asset = release.assets.find((a) => /\.(tar\.gz|zip)$/.test(a.name) && a.name.includes(`-${suffix}.`));
    if (!asset) continue;
    const a = link(asset.browser_download_url, label);
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = `${asset.name} · ${megabytes(asset.size)}`;
    a.append(name);
    const item = document.createElement("li");
    item.append(a);
    files.append(item);
  }

  const extras = document.getElementById("extras");
  const sums = release.assets.find((a) => a.name.endsWith("sha256sums.txt"));
  if (sums) extras.prepend(link(sums.browser_download_url, "Checksums"), " · ");
}

showLatest().catch(() => {});
