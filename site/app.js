const menuButton = document.querySelector(".menu-button");
const navigation = document.querySelector(".site-nav");
const copyStatus = document.querySelector(".copy-status");
let copyStatusTimer;

menuButton?.addEventListener("click", () => {
  const isOpen = menuButton.getAttribute("aria-expanded") === "true";
  menuButton.setAttribute("aria-expanded", String(!isOpen));
  navigation?.classList.toggle("is-open", !isOpen);
});

navigation?.addEventListener("click", (event) => {
  if (!(event.target instanceof HTMLAnchorElement)) return;
  menuButton?.setAttribute("aria-expanded", "false");
  navigation.classList.remove("is-open");
});

async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const input = document.createElement("textarea");
  input.value = text;
  input.setAttribute("readonly", "");
  input.style.position = "fixed";
  input.style.opacity = "0";
  document.body.append(input);
  input.select();
  const copied = document.execCommand("copy");
  input.remove();
  if (!copied) throw new Error("copy failed");
}

function showCopyStatus(message) {
  if (!copyStatus) return;
  window.clearTimeout(copyStatusTimer);
  copyStatus.textContent = message;
  copyStatus.classList.add("is-visible");
  copyStatusTimer = window.setTimeout(() => {
    copyStatus.classList.remove("is-visible");
  }, 1800);
}

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const text = button.getAttribute("data-copy");
    if (!text) return;

    try {
      await copyText(text);
      button.classList.add("is-copied");
      button.textContent = "已复制";
      showCopyStatus("命令已复制");
      window.setTimeout(() => {
        button.classList.remove("is-copied");
        button.textContent = "复制";
      }, 1800);
    } catch {
      showCopyStatus("复制失败，请手动选择命令");
    }
  });
});
